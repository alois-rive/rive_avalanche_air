#!/usr/bin/env python3
"""The course's props, procedural and low-poly (docs/LOOK.md, section 4;
docs/ASSETS.md, section 2, within its budgets): chalets, the start hut and
gate, the lodge, the lift pylons and chairs, the gondola station (the HG
gap's roof) and its cabins, inflatable arches (start, split, finish, the
mega-jump's neon), sponsor banners, snow fences, the crowd, the cone-stack
pines, and the features' own meshes (rails, boxes, logs, the kickers' lip
lines).

PLACEHOLDERS for the asset pipeline (ASSETS.md): each builder is a few
boxes, prisms and cones in the meshes module's primitives, textured from
the pages tools/make_textures.py draws (tools/course/pages.py). The course
generator calls Dressing: it places the props from course.py's table,
keeps the forest off them, adds their obstacles, and bakes them into
world/course/dressing.rmdlcmd (Hedra's data form: one object a region of
the course and a material, so a stretch of props costs a few draws).

    python3 tools/make_props.py     # prints each prop's triangle count against its budget
"""
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "course"))
sys.dont_write_bytecode = True

import course as C  # noqa: E402
import pages  # noqa: E402
from meshes import Mesh, Xf, box, cone, quad, tube  # noqa: E402

REGION = 144.0      # metres of z a dressing region


def heading_yaw(dx, dz):
    """The yaw that turns a prop's -Z (its front looks +Z) along (dx, dz)."""
    return math.atan2(-dx, -dz)


class Bag:
    """Meshes by material for one prop or region."""

    def __init__(self, prefix=""):
        self.prefix = prefix
        self.m = {}

    def __call__(self, mat):
        if mat not in self.m:
            self.m[mat] = Mesh(self.prefix + mat, mat)
        return self.m[mat]

    def tris(self):
        return sum(m.tris() for m in self.m.values())


# ---- builders: each draws into a Bag at a placement ---------------------------

def chalet(bag, xf, w=6.0, d=7.0, h=3.2, roof_h=2.6):
    B = pages.BUILDING
    box(bag("building"), xf, -w / 2, w / 2, 0, h, -d / 2, d / 2, uvr=pages.uv(B, "planks"), tile=3.0, faces="blrd")
    box(bag("building"), xf, -w / 2, w / 2, 0, h, -d / 2, d / 2, uvr=pages.uv(B, "window"), faces="f")
    # the gables and the roof: two slabs meeting on the ridge
    over = 0.6
    for side in (-1, 1):
        a = xf((side * (w / 2 + over), h - 0.3, d / 2 + over))
        b = xf((0, h + roof_h, d / 2 + over))
        c = xf((0, h + roof_h, -d / 2 - over))
        e = xf((side * (w / 2 + over), h - 0.3, -d / 2 - over))
        pts = [a, b, c, e] if side < 0 else [b, a, e, c]
        bag("building").face(pts, [(0, 0.75), (0.5, 0.5), (0.5, 0.5), (0, 0.75)], False)
        roof = pages.uv(B, "roof")
        if side < 0:
            bag("building").face([a, e, c, b], [(roof[0], roof[3]), (roof[2], roof[3]), (roof[2], roof[1]), (roof[0], roof[1])], False)
        else:
            bag("building").face([e, a, b, c], [(roof[0], roof[3]), (roof[2], roof[3]), (roof[2], roof[1]), (roof[0], roof[1])], False)
    # the gable ends (triangles) front and back
    for zz, flip in ((d / 2, False), (-d / 2, True)):
        p = [xf((-w / 2, h, zz)), xf((w / 2, h, zz)), xf((0, h + roof_h - 0.2, zz))]
        if flip:
            p = [p[1], p[0], p[2]]
        pl = pages.uv(B, "timber")
        bag("building").face(p, [(pl[0], pl[3]), (pl[2], pl[3]), ((pl[0] + pl[2]) / 2, pl[1])], False)


def start_hut(bag, xf):
    chalet(bag, xf, 3.6, 3.6, 2.6, 1.6)
    box(bag("building"), xf, -0.5, 0.5, 0, 2.2, 1.79, 1.82, uvr=pages.uv(pages.BUILDING, "door"), faces="f")


def gate(bag, xf, width):
    L = pages.LIFT
    for side in (-1, 1):
        box(bag("lift"), xf, side * width / 2 - 0.15, side * width / 2 + 0.15, 0, 2.6, -0.15, 0.15, uvr=pages.uv(L, "yellow"))
    box(bag("lift"), xf, -width / 2, width / 2, 2.4, 2.7, -0.12, 0.12, uvr=pages.uv(L, "yellow"))
    # the bar the rider pushes off (it lifts at GO: a later timeline)
    box(bag("lift"), xf, -width / 2 + 0.3, width / 2 - 0.3, 0.75, 0.85, -0.05, 0.05, uvr=pages.uv(L, "station"))


def arch(bag, xf, width, region, neon=False, height=6.5):
    """The inflatable arch: two fat legs, a bulging beam, a sign panel on its
    face (the page's top half: the words; the bottom half: the stripes)."""
    A = pages.ARCHES
    x0, y0, x1, y1 = pages.uv(A, region)
    stripes = (x0, (y0 + y1) / 2, x1, y1)
    words = (x0, y0, x1, (y0 + y1) / 2)
    r = 0.85
    m = bag("arch")
    for side in (-1, 1):
        tube(m, xf((side * width / 2, -0.3, 0)), xf((side * width / 2, height - 0.6, 0)), r, 8, stripes)
    n = 8
    pts = []
    for k in range(n + 1):
        t = k / n
        x = -width / 2 + width * t
        y = height - 0.6 + 1.2 * math.sin(math.pi * t)
        pts.append(xf((x, y, 0)))
    for k in range(n):
        tube(m, pts[k], pts[k + 1], r, 8, stripes)
    # the panel: both faces read
    pw = min(width * 0.62, 9.0)
    py = height + 0.25
    panel = bag("neon" if neon else "arch")
    box(panel, xf, -pw / 2, pw / 2, py - 0.8, py + 0.8, r * 0.6, r * 0.6 + 0.15, uvr=words, faces="fb")
    box(panel, xf, -pw / 2, pw / 2, py - 0.8, py + 0.8, r * 0.6, r * 0.6 + 0.15, uvr=stripes, faces="lrtd")


def span_banner(bag, xf, width, sponsor):
    B = pages.BANNERS
    L = pages.LIFT
    for side in (-1, 1):
        tube(bag("lift"), xf((side * width / 2, -0.2, 0)), xf((side * width / 2, 5.4, 0)), 0.14, 6, pages.uv(L, "steel"))
    # panels of the page's 2:1 proportion, the sponsor alternating with the resort
    inner = width - 0.4
    n = max(1, int(round(inner / 4.0)))
    pw = inner / n
    for k in range(n):
        x0 = -inner / 2 + k * pw
        sp = sponsor if k % 2 == 0 else "neonpeak" if sponsor != "neonpeak" else "avalanche"
        box(bag("banner"), xf, x0, x0 + pw, 3.2, 5.2, -0.04, 0.04, uvr=pages.uv(B, sp), faces="fb")


def post_banner(bag, xf, sponsor):
    B = pages.BANNERS
    L = pages.LIFT
    for side in (-1, 1):
        tube(bag("lift"), xf((side * 1.2, -0.2, 0)), xf((side * 1.2, 2.3, 0)), 0.07, 4, pages.uv(L, "steel"))
    box(bag("banner"), xf, -1.2, 1.2, 1.0, 2.2, -0.03, 0.03, uvr=pages.uv(B, sponsor), faces="fb")


def fence(bag, a, b, h=1.2):
    """A snow fence panel from a to b (scene points on the snow)."""
    length = math.hypot(b[0] - a[0], b[2] - a[2])
    reps = max(1, round(length / 2.0))
    m = bag("fence")
    m.face([a, b, (b[0], b[1] + h, b[2]), (a[0], a[1] + h, a[2])], [(0, 1), (reps, 1), (reps, 0), (0, 0)], False)


def pylon(bag, base, top_y, yaw, width=4.4):
    L = pages.LIFT
    h = top_y - base[1]
    tube(bag("lift"), (base[0], base[1] - 0.5, base[2]), (base[0], top_y, base[2]), 0.32, 6, pages.uv(L, "steel"), r1=0.24)
    xf = Xf((base[0], top_y, base[2]), yaw)
    box(bag("lift"), xf, -width / 2, width / 2, -0.25, 0.25, -0.3, 0.3, uvr=pages.uv(L, "yellow"))
    return h


def chair(bag, at, yaw):
    L = pages.LIFT
    xf = Xf((at[0], at[1], at[2]), yaw)
    tube(bag("lift"), xf((0, 0, 0)), xf((0, -1.9, 0)), 0.05, 4, pages.uv(L, "cable"))
    box(bag("lift"), xf, -0.9, 0.9, -2.3, -2.15, -0.35, 0.35, uvr=pages.uv(L, "seat"))
    box(bag("lift"), xf, -0.9, 0.9, -2.15, -1.6, 0.3, 0.38, uvr=pages.uv(L, "seat"))


def cabin(bag, at, yaw):
    L = pages.LIFT
    xf = Xf((at[0], at[1], at[2]), yaw)
    tube(bag("lift"), xf((0, 0, 0)), xf((0, -1.2, 0)), 0.06, 4, pages.uv(L, "cable"))
    box(bag("lift"), xf, -1.0, 1.0, -3.4, -1.2, -1.0, 1.0, uvr=pages.uv(L, "cabin"))


def cable(bag, a, b):
    tube(bag("lift"), a, b, 0.06, 3, pages.uv(pages.LIFT, "cable"), smooth=False)


def cone_pine(bag, base, h, yaw):
    m = bag("pine_cone")
    tiers = ((0.18, 0.42, 0.34), (0.42, 0.34, 0.27), (0.62, 0.38, 0.18))
    for y0, hh, rr in tiers:
        cone(m, (base[0], base[1] + y0 * h, base[2]), rr * h, hh * h, 6, (0, 0, 1, 1))
    tube(m, (base[0], base[1] - 0.3, base[2]), (base[0], base[1] + 0.2 * h, base[2]), 0.18, 4, (0.0, 0.85, 0.2, 1.0))


def crowd(bag, xf, n, rng_k=0):
    m = bag("crowd")
    keys = "abcd"
    for i in range(n):
        reg = pages.uv(pages.CROWD, keys[(i + rng_k) % 4])
        x0 = -n * 0.45 + i * 0.9
        p = [xf((x0, 0, 0)), xf((x0 + 0.9, 0, 0)), xf((x0 + 0.9, 1.8, 0)), xf((x0, 1.8, 0))]
        m.face(p, [(reg[0], reg[3]), (reg[2], reg[3]), (reg[2], reg[1]), (reg[0], reg[1])], False)


def station(bag, frame_, roof, ground):
    """The gondola station under the HG gap: walls from the slope up to its
    flat roof (the rideable landing for the slow), the roof's snow (packed)."""
    ox, oz, fx, fz, rx, rz = frame_
    u0, u1, hw, top = roof["u0"], roof["u1"], roof["half_w"], roof["top"]
    B = pages.BUILDING

    def P(u, v, y):
        return (ox + fx * u + rx * v, y, oz + fz * u + rz * v)
    corners = [(u0, -hw), (u1, -hw), (u1, hw), (u0, hw)]
    walls = bag("building")
    for k in range(4):
        ua, va = corners[k]
        ub, vb = corners[(k + 1) % 4]
        ga = ground(*P(ua, va, 0)[::2]) - 1.0
        gb = ground(*P(ub, vb, 0)[::2]) - 1.0
        length = math.hypot(ub - ua, vb - va)
        reg = pages.uv(B, "concrete")
        # facing out: corners go round counter-clockwise seen from above
        a = P(ua, va, ga)
        b = P(ub, vb, gb)
        walls.face([b, a, P(ua, va, top), P(ub, vb, top)],
                   [(reg[0], reg[3]), (reg[0] + length / 4 * (reg[2] - reg[0]), reg[3]),
                    (reg[0] + length / 4 * (reg[2] - reg[0]), reg[1]), (reg[0], reg[1])], False)
        # a band of windows under the roof
        wreg = pages.uv(B, "window")
        walls.face([P(ub, vb, top - 2.6), P(ua, va, top - 2.6), P(ua, va, top - 0.4), P(ub, vb, top - 0.4)],
                   [(wreg[0], wreg[3]), (wreg[2], wreg[3]), (wreg[2], wreg[1]), (wreg[0], wreg[1])], False)
    snow = bag("packed")
    n_u = int(math.ceil((u1 - u0) / 1.5))
    n_v = int(math.ceil(2 * hw / 1.5))
    for i in range(n_u):
        for k in range(n_v):
            ua = u0 + (u1 - u0) * i / n_u
            ub = u0 + (u1 - u0) * (i + 1) / n_u
            va = -hw + 2 * hw * k / n_v
            vb = -hw + 2 * hw * (k + 1) / n_v
            pts = [P(ua, va, top), P(ua, vb, top), P(ub, vb, top), P(ub, va, top)]
            # counter-clockwise from above: forward x right
            snow.face(pts if (fx * rz - fz * rx) < 0 else pts[::-1], [(p[0] / 3, -p[2] / 3) for p in pts], False)


# ---- the dressing ----------------------------------------------------------------

class Dressing:
    def __init__(self, data, forest):
        self.data = data
        self.forest = forest
        self.ops = []          # (z, builder) to run into the region's bag

    def ground(self, x, z):
        g = self.data.ground(x, z)
        return g[0] if g else 0.0

    def on_line(self, samples, s, x=0.0):
        i = max(0, min(len(samples) - 1, int(round(s - samples[0]["own_s"]))))
        p = samples[i]
        t = p["t"]
        n = math.hypot(t[0], t[2])
        dx, dz = t[0] / n, t[2] / n
        px = p["x"] + (-dz) * x
        pz = p["z"] + dx * x
        return (px, self.ground(px, pz), pz), (dx, dz), p

    def keep(self, x, z, r):
        self.forest.keep_out.append((x, z, r))

    def obstacle(self, x, z, r, bottom, top):
        self.forest.extra_obstacles.append(dict(x=x, z=z, r=r, bottom=bottom, top=top, kind="prop"))

    def add(self, z, fn):
        self.ops.append((z, fn))

    def place(self):
        d = self.data
        m = d.main_samples
        hs = d.high_samples
        # the start: gate, hut, chalets
        p, (dx, dz), smp = self.on_line(m, 0.0)
        yaw = heading_yaw(dx, dz)
        self.add(p[2], lambda bag, p=p, yaw=yaw: gate(bag, Xf(p, yaw), 12.0))
        for side in (-1, 1):
            self.obstacle(p[0] + side * 6, p[2], 0.25, p[1] - 1, p[1] + 3)
        hut = (8.5, self.ground(8.5, 8.0), 8.0)
        self.add(hut[2], lambda bag, hut=hut: start_hut(bag, Xf(hut, 0.4)))
        self.circles(hut, 2.0, 2.6, hut[1] + 4)
        for cx, cz, yw in ((-16.0, 14.0, 0.2), (22.0, 20.0, -0.3), (-28.0, -4.0, 0.9)):
            c = (cx, self.ground(cx, cz), cz)
            self.add(cz, lambda bag, c=c, yw=yw: chalet(bag, Xf(c, yw)))
            self.circles(c, 3.8, 3.0, c[1] + 6)
        # arches
        for name, s in C.ARCHES:
            p, (dx, dz), smp = self.on_line(m, s)
            w = smp["width"] + 3.0
            yaw = heading_yaw(dx, dz)
            self.add(p[2], lambda bag, p=p, yaw=yaw, w=w, name=name: arch(bag, Xf(p, yaw), w, name, neon=(name == "finish")))
            for side in (-1, 1):
                self.obstacle(p[0] + (-dz) * side * w / 2, p[2] + dx * side * w / 2, 0.9, p[1] - 1, p[1] + 7)
        # the mega-jump's neon arch over its lip
        j = d.mega.j
        ox, oz, fx, fz, rx, rz = d.feats.mega_frame
        pm = (ox - fx * 2.0, j.y0 - 3.4, oz - fz * 2.0)
        yaw = heading_yaw(fx, fz)
        self.add(pm[2], lambda bag, pm=pm, yaw=yaw: arch(bag, Xf(pm, yaw), j.width + 6, "mega", neon=True, height=9.5))
        for side in (-1, 1):
            self.obstacle(pm[0] + rx * side * (j.width + 6) / 2, pm[2] + rz * side * (j.width + 6) / 2, 0.9, pm[1] - 2, pm[1] + 10)
        # span banners
        sponsors = ["frostbyte", "neonpeak", "chillwave", "avalanche"]
        for k, s in enumerate(C.SPANS):
            p, (dx, dz), smp = self.on_line(m, s)
            w = smp["width"] + 2.0
            yaw = heading_yaw(dx, dz)
            sp = sponsors[k % len(sponsors)]
            self.add(p[2], lambda bag, p=p, yaw=yaw, w=w, sp=sp: span_banner(bag, Xf(p, yaw), w, sp))
            for side in (-1, 1):
                self.obstacle(p[0] + (-dz) * side * w / 2, p[2] + dx * side * w / 2, 0.2, p[1] - 1, p[1] + 5)
        # post banners along the edges
        post_s = [100, 180, 265, 380, 450, 540, 590, 700, 820, 960, 1110, 1270, 1290, 1445]
        post_sp = ["pow", "radical", "frostbyte", "chillwave", "neonpeak", "pow", "radical", "avalanche"]
        for k, s in enumerate(post_s):
            side = 1 if k % 2 == 0 else -1
            p0, (dx, dz), smp = self.on_line(m, s)
            p, _d, _ = self.on_line(m, s, side * (smp["width"] / 2 + 2.5))
            yaw = heading_yaw(dx, dz)
            sp = post_sp[k % len(post_sp)]
            self.add(p[2], lambda bag, p=p, yaw=yaw, sp=sp: post_banner(bag, Xf(p, yaw), sp))
            self.keep(p[0], p[2], 2.5)
        # the split's arch reads HIGH LINE <- and LOW LINE ->: banners on it
        # snow fences along both edges of the warm-up slope
        for side in (-1, 1):
            s = 40.0
            while s < 330.0:
                a, _d, smp = self.on_line(m, s, side * (smp_w(m, s) / 2 + 1.0))
                b, _d, _ = self.on_line(m, s + 4.0, side * (smp_w(m, s + 4.0) / 2 + 1.0))
                self.add(a[2], lambda bag, a=a, b=b: fence(bag, a, b))
                s += 4.0
        # the lifts
        self.lift1()
        self.lift2()
        self.gondola()
        # the finish: lodge, chalets, crowd behind fences
        fs = C.FINISH_S
        for k, (s, x, yw, big) in enumerate(((fs + 25, -26.0, 0.0, True), (fs + 12, 24.0, -0.2, False), (fs + 40, 26.0, 0.3, False))):
            c, (dx, dz), _ = self.on_line(m, s, x)
            yaw = heading_yaw(dx, dz) + yw
            if big:
                self.add(c[2], lambda bag, c=c, yaw=yaw: chalet(bag, Xf(c, yaw), 12.0, 9.0, 4.2, 3.2))
                self.circles(c, 6.0, 3.5, c[1] + 8)
            else:
                self.add(c[2], lambda bag, c=c, yaw=yaw: chalet(bag, Xf(c, yaw)))
                self.circles(c, 3.8, 3.0, c[1] + 6)
        for s0, s1 in ((fs - 30, fs + 15), (585.0, 640.0)):
            for side in (-1, 1):
                s = s0
                k = 0
                while s < s1:
                    w = smp_w(m, s)
                    a, (dx, dz), _ = self.on_line(m, s, side * (w / 2 + 2.0))
                    b, _d, _ = self.on_line(m, s + 3.0, side * (w / 2 + 2.0))
                    self.add(a[2], lambda bag, a=a, b=b: fence(bag, a, b, 1.0))
                    c, _d, _ = self.on_line(m, s + 1.5, side * (w / 2 + 3.2))
                    yaw = heading_yaw(dx, dz) + (math.pi / 2 if side < 0 else -math.pi / 2)
                    self.add(c[2], lambda bag, c=c, yaw=yaw, k=k: crowd(bag, Xf(c, yaw), 3, k))
                    self.keep(c[0], c[2], 3.0)
                    s += 3.0
                    k += 1
        # the cone-stack pines (placed by the forest; built here)
        # (the forest scatters after place(): meshes() reads its cones)

    def circles(self, c, radius, r, top):
        for k in range(6):
            a = k * math.pi / 3
            self.obstacle(c[0] + radius * 0.6 * math.cos(a), c[2] + radius * 0.6 * math.sin(a), r, c[1] - 1, top)
        self.keep(c[0], c[2], radius + 4)

    # ---- the lifts -----------------------------------------------------------
    def lift_line(self, a, b, n_pylons, n_chairs, clearance, bag_z_from=None):
        """A chairlift from a to b (plan points), its cable `clearance` m above
        the highest ground under it: pylons, cable, chairs both ways."""
        ga = self.ground(a[0], a[2])
        gb = self.ground(b[0], b[2])
        # the cable: straight from end to end, raised to clear every pylon's ground
        ya = ga + clearance
        yb = gb + clearance
        for k in range(n_pylons):
            t = k / (n_pylons - 1)
            x = a[0] + (b[0] - a[0]) * t
            z = a[2] + (b[2] - a[2]) * t
            g = self.ground(x, z)
            yc = ya + (yb - ya) * t
            if yc < g + clearance:
                lift = g + clearance - yc
                ya += lift
                yb += lift
        dx = b[0] - a[0]
        dz = b[2] - a[2]
        L = math.hypot(dx, dz)
        yaw = heading_yaw(dx / L, dz / L)
        side = (-dz / L, dx / L)
        for k in range(n_pylons):
            t = k / (n_pylons - 1)
            x = a[0] + dx * t
            z = a[2] + dz * t
            g = self.ground(x, z)
            yc = ya + (yb - ya) * t
            base = (x, g, z)
            self.add(z, lambda bag, base=base, yc=yc, yaw=yaw: pylon(bag, base, yc + 0.4, yaw))
            self.obstacle(x, z, 0.45, g - 1, yc)
        for k in range(int(L / 4)):
            t = k * 4 / L
            self.keep(a[0] + dx * t, a[2] + dz * t, 3.5)
        for lane in (-1, 1):
            pa = (a[0] + side[0] * 2.0 * lane, ya, a[2] + side[1] * 2.0 * lane)
            pb = (b[0] + side[0] * 2.0 * lane, yb, b[2] + side[1] * 2.0 * lane)
            # the cable in pieces, so each region draws its own
            n = max(1, int(L / 60))
            for k in range(n):
                t0, t1 = k / n, (k + 1) / n
                q0 = tuple(pa[i] + (pb[i] - pa[i]) * t0 for i in range(3))
                q1 = tuple(pb[i] * t1 + pa[i] * (1 - t1) for i in range(3))
                self.add(q0[2], lambda bag, q0=q0, q1=q1: cable(bag, q0, q1))
            per = n_chairs // 2
            for k in range(per):
                t = (k + 0.5 * (lane + 1) / 2) / per
                at = tuple(pa[i] + (pb[i] - pa[i]) * t for i in range(3))
                self.add(at[2], lambda bag, at=at, yaw=yaw: chair(bag, at, yaw))
        return ya, yb

    def lift1(self):
        P = C.LIFT1
        m = self.data.main_samples
        a, _d, _ = self.on_line(m, P["s1"], P["x"])
        b, _d, _ = self.on_line(m, P["s0"], P["x"])
        self.lift_line(a, b, P["pylons"], P["chairs"], 8.0)

    def lift2(self):
        P = C.LIFT2
        m = self.data.main_samples
        a, _d, _ = self.on_line(m, P["s1"], P["x1"])
        b, _d, _ = self.on_line(m, P["s0"], P["x0"])
        self.lift_line(a, b, P["pylons"], P["chairs"], P["height"])

    def gondola(self):
        d = self.data
        rf = d.feats.roof
        ox, oz, fx, fz, rx, rz = rf["frame"]
        um = (rf["u0"] + rf["u1"]) / 2
        st = (ox + fx * um, rf["top"], oz + fz * um)
        self.add(st[2], lambda bag: station(bag, rf["frame"], rf, self.ground))
        # its walls: circles round the footprint, as tall as the roof
        for u in range(int(rf["u0"]), int(rf["u1"]) + 1, 3):
            for v in (-rf["half_w"], rf["half_w"]):
                x = ox + fx * u + rx * v
                z = oz + fz * u + rz * v
                self.obstacle(x, z, 1.4, self.ground(x, z) - 1, rf["top"] - 0.05)
        for v in range(int(-rf["half_w"]), int(rf["half_w"]) + 1, 3):
            for u in (rf["u0"], rf["u1"]):
                x = ox + fx * u + rx * v
                z = oz + fz * u + rz * v
                self.obstacle(x, z, 1.4, self.ground(x, z) - 1, rf["top"] - 0.05)
        self.keep(st[0], st[2], 16.0)
        # the gondola's cable: from the station's roof up the hill, left of the high line
        m = d.main_samples
        top, _d, _ = self.on_line(m, 820.0, -62.0)
        a = (st[0] - rx * 4, st[1], st[2] - rz * 4)
        n_py = C.GONDOLA["pylons"]
        ya = st[1] + 6.0
        yb = top[1] + 10.0
        L = math.hypot(top[0] - a[0], top[2] - a[2])
        yaw = heading_yaw((top[0] - a[0]) / L, (top[2] - a[2]) / L)
        for k in range(1, n_py + 1):
            t = k / (n_py + 1)
            x = a[0] + (top[0] - a[0]) * t
            z = a[2] + (top[2] - a[2]) * t
            g = self.ground(x, z)
            yc = max(ya + (yb - ya) * t, g + 9.0)
            base = (x, g, z)
            self.add(z, lambda bag, base=base, yc=yc, yaw=yaw: pylon(bag, base, yc + 0.4, yaw, 5.0))
            self.obstacle(x, z, 0.5, g - 1, yc)
            self.keep(x, z, 4.0)
        sx, sz = -(top[2] - a[2]) / L, (top[0] - a[0]) / L
        for lane in (-1, 1):
            pa = (a[0] + sx * 2.5 * lane, ya, a[2] + sz * 2.5 * lane)
            pb = (top[0] + sx * 2.5 * lane, yb, top[2] + sz * 2.5 * lane)
            n = 4
            for k in range(n):
                q0 = tuple(pa[i] + (pb[i] - pa[i]) * k / n for i in range(3))
                q1 = tuple(pa[i] + (pb[i] - pa[i]) * (k + 1) / n for i in range(3))
                self.add(q0[2], lambda bag, q0=q0, q1=q1: cable(bag, q0, q1))
            for k in range(C.GONDOLA["cabins"] // 2):
                t = (k + 0.5 + 0.25 * lane) / (C.GONDOLA["cabins"] // 2)
                at = tuple(pa[i] + (pb[i] - pa[i]) * t for i in range(3))
                self.add(at[2], lambda bag, at=at, yaw=yaw: cabin(bag, at, yaw))

    # ---- the features' meshes ---------------------------------------------------
    def feature_ops(self):
        d = self.data
        for rl in d.rails:
            self.add(rl["pts"][0][2], lambda bag, rl=rl: rail_mesh(bag, rl, self.ground))
        for j in d.feats.jumps:
            if j.kind in ("kicker", "gap", "mega"):
                ov = next(o for o in d.feats.overlays if o.id == j.id)
                self.add(ov.frame[1], lambda bag, j=j, ov=ov: lip_line(bag, j, ov, d))
        for x, y, z, h, yaw in self.forest.cones:
            self.add(z, lambda bag, x=x, y=y, z=z, h=h, yaw=yaw: cone_pine(bag, (x, y, z), h, yaw))

    def meshes(self):
        """The props baked into regions: one mesh a region and material."""
        self.feature_ops()
        g = self.data.grid
        bags = {}
        for z, fn in self.ops:
            ri = max(0, int((g.Z0 - z) // REGION))
            bag = bags.get(ri)
            if bag is None:
                bag = Bag("D%02d_" % ri)
                bags[ri] = bag
            fn(bag)
        out = []
        for ri in sorted(bags):
            for mat in sorted(bags[ri].m):
                mm = bags[ri].m[mat]
                if mm.faces:
                    out.append(mm)
        self.ops = []
        return out


def smp_w(samples, s):
    i = max(0, min(len(samples) - 1, int(round(s - samples[0]["own_s"]))))
    return samples[i]["width"]


def rail_mesh(bag, rl, ground):
    pts = rl["pts"]
    kind = rl["kind_name"]
    step = 4
    idx = list(range(0, len(pts), step))
    if idx[-1] != len(pts) - 1:
        idx.append(len(pts) - 1)
    if kind == "rail":
        m = bag("rail")
        for a, b in zip(idx, idx[1:]):
            tube(m, pts[a], pts[b], 0.06, 6, (0, 0, 1, 1))
        for k in range(0, len(pts), 12):
            p = pts[k]
            g = ground(p[0], p[2])
            tube(bag("lift"), (p[0], g - 0.3, p[2]), (p[0], p[1] - 0.05, p[2]), 0.05, 4, pages.uv(pages.LIFT, "steel"))
    elif kind == "box":
        m = bag("box")
        hw = rl["width"] / 2
        ox, oz, fx, fz, rx, rz = rl["frame"]
        for a, b in zip(idx, idx[1:]):
            pa, pb = pts[a], pts[b]
            ga = ground(pa[0], pa[2]) - 0.3
            gb = ground(pb[0], pb[2]) - 0.3

            def P(p, v, y):
                return (p[0] + rx * v, y, p[2] + rz * v)
            u0 = a * 0.25 / 2.0
            u1 = b * 0.25 / 2.0
            m.face([P(pa, -hw, pa[1]), P(pa, hw, pa[1]), P(pb, hw, pb[1]), P(pb, -hw, pb[1])],
                   [(0, u0), (1, u0), (1, u1), (0, u1)], False)
            for v, flip in ((-hw, False), (hw, True)):
                q = [P(pa, v, ga), P(pb, v, gb), P(pb, v, pb[1]), P(pa, v, pa[1])]
                if flip:
                    q = [q[1], q[0], q[3], q[2]]
                m.face(q, [(0, 0.95), (1, 0.95), (1, 0.75), (0, 0.75)], False)
        # the ends
        for p, flip in ((pts[0], True), (pts[-1], False)):
            g = ground(p[0], p[2]) - 0.3
            q = [(p[0] - rx * hw, g, p[2] - rz * hw), (p[0] + rx * hw, g, p[2] + rz * hw),
                 (p[0] + rx * hw, p[1], p[2] + rz * hw), (p[0] - rx * hw, p[1], p[2] - rz * hw)]
            if flip:
                q = [q[1], q[0], q[3], q[2]]
            m.face(q, [(0, 0.95), (1, 0.95), (1, 0.75), (0, 0.75)], False)
    else:
        m = bag("bark")
        r = rl["width"] / 2
        for a, b in zip(idx, idx[1:]):
            pa = (pts[a][0], pts[a][1] - r, pts[a][2])
            pb = (pts[b][0], pts[b][1] - r, pts[b][2])
            tube(m, pa, pb, r, 8, (0, 0, 1, 0.5))
        for p in (pts[0], pts[-1]):
            g = ground(p[0], p[2])
            box(bag("bark"), Xf((p[0], g - 0.3, p[2])), -0.5, 0.5, 0, p[1] - g - r + 0.3, -0.15, 0.15, uvr=(0, 0.5, 1, 1))


def lip_line(bag, j, ov, data):
    """The acid-green line on a kicker's lip (LOOK.md, section 4)."""
    ox, oz, fx, fz, rx, rz = ov.frame
    m = bag("accent")
    hw = j.width / 2
    n = max(2, int(math.ceil(2 * hw / 1.5)))
    for k in range(n):
        va = -hw + 2 * hw * k / n
        vb = -hw + 2 * hw * (k + 1) / n
        pts = []
        for u, v in ((-0.35, va), (-0.35, vb), (-0.02, vb), (-0.02, va)):
            x = ox + fx * u + rx * v
            z = oz + fz * u + rz * v
            g = data.ground(x, z)
            pts.append((x, (g[0] if g else 0) + 0.05, z))
        # counter-clockwise from above
        cr = (pts[1][0] - pts[0][0]) * (pts[2][2] - pts[0][2]) - (pts[1][2] - pts[0][2]) * (pts[2][0] - pts[0][0])
        if cr > 0:
            pts = pts[::-1]
        m.face(pts, [(0, 0), (1, 0), (1, 1), (0, 1)], False)


BUDGETS = [("chalet", lambda b: chalet(b, Xf()), 300), ("start hut", lambda b: start_hut(b, Xf()), 160),
           ("lodge", lambda b: chalet(b, Xf(), 12.0, 9.0, 4.2, 3.2), 500), ("arch", lambda b: arch(b, Xf(), 14.0, "start"), 200),
           ("span banner", lambda b: span_banner(b, Xf(), 32.0, "pow"), 40),
           ("post banner", lambda b: post_banner(b, Xf(), "pow"), 16),
           ("pylon", lambda b: pylon(b, (0, 0, 0), 10.0, 0.0), 80), ("chair", lambda b: chair(b, (0, 10, 0), 0.0), 40),
           ("cabin", lambda b: cabin(b, (0, 10, 0), 0.0), 120), ("cone pine", lambda b: cone_pine(b, (0, 0, 0), 7.0, 0.0), 40),
           ("fence", lambda b: fence(b, (0, 0, 0), (4, 0, 0)), 12), ("gate", lambda b: gate(b, Xf(), 12.0), 160)]


def main():
    ok = True
    for name, fn, budget in BUDGETS:
        b = Bag()
        fn(b)
        t = b.tris()
        print("%-12s %4d triangles (budget %d)%s" % (name, t, budget, "" if t <= budget else "  OVER"))
        ok = ok and t <= budget
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
