"""Builds the course from course.py: the lines, the jumps and the other
features, the terrain grid, the rails, the line samples. make_course.py
writes what this computes."""
import math

import course as C
from geom import (DEG, DROP_FACE, Jump, Line, design_drop, design_kicker, evaluate, fbm, hermite, hermite_d, held_blended,
                  lerp, meander_x, bow, section_width, smoothstep, flight)

G = C.GRID
BLK = C.BLOCK * G            # a coarse block's side (m)


# ============================================================================
# the lines
# ============================================================================

class Mega:
    """The mega-jump's numbers in its lip's frame (geom.Jump), evaluated
    before the main line is built: the line's base after the lip is its
    gap (a chord to the knuckle) and its landing."""

    def __init__(self):
        m = C.MEGA
        self.j = Jump(m["id"], "mega", "main", m["s"], m["x"], m["lip_h"], m["lip_deg"] * DEG,
                      m["land_deg"] * DEG, m["v"], m["width"])
        self.j.xk = m["knuckle"]
        self.j.yk = m["knuckle_y"]
        evaluate(self.j)
        drop = -(self.j.yk + self.j.h)          # the base's fall from the lip's foot to the knuckle
        self.chord_angle = math.atan2(drop, self.j.xk)
        self.chord_len = math.hypot(drop, self.j.xk)
        self.s_knuckle = m["s"] + self.chord_len
        self.s_land_end = self.s_knuckle + (self.j.xe - self.j.xk) / math.cos(self.j.alpha)


def main_slope_fn(mega):
    knots = C.PROFILE
    a = C.MEGA_LIP_S
    k = mega.s_knuckle
    e = mega.s_land_end
    alpha = mega.j.alpha
    run = C.RUNOUT_DEG * DEG

    def slope(s):
        if s < a:
            return held_blended(knots, s, C.PROFILE_BLEND, C.BLEND) * DEG
        if s < k - 1.0:
            return mega.chord_angle
        if s < k + 1.0:
            return lerp(mega.chord_angle, alpha, smoothstep((s - (k - 1.0)) / 2.0))
        if s < e:
            return alpha
        if s < e + 24.0:
            return lerp(alpha, run, smoothstep((s - e) / 24.0))
        if s < C.FLAT_S - 6.0:
            return run
        if s < C.FLAT_S + 6.0:
            return lerp(run, 0.0, smoothstep((s - (C.FLAT_S - 6.0)) / 12.0))
        return 0.0
    return slope


def low_x(s):
    x = meander_x(s)
    if C.SPLIT_S < s < C.MERGE_S:
        x += C.LOW_BOW * bow((s - C.SPLIT_S) / (C.MERGE_S - C.SPLIT_S))
    return x


def main_width(s):
    if C.SPLIT_S < s < C.MERGE_S:
        t = (s - C.SPLIT_S) / (C.MERGE_S - C.SPLIT_S)
        return lerp(section_width(s), C.LOW_WIDTH, smoothstep(min(t, 1 - t) * 8))
    return section_width(s)


def build_lines():
    mega = Mega()
    main = Line("Line").build(0.0, (0.0, 0.0, 0.0), C.LINE_END, main_slope_fn(mega), low_x, main_width)
    main.z_index()
    s0 = C.SPLIT_S
    s1 = s0 + C.HIGH_LENGTH
    span = C.MERGE_S - C.SPLIT_S
    p0 = main.at(s0)
    p_end = main.at(C.MERGE_S)
    beta_in = main.value(main.slope, s0)
    beta_out = main.value(main.slope, C.MERGE_S)

    def mapped(sh):
        return C.SPLIT_S + (sh - s0) * span / C.HIGH_LENGTH

    def make(beta_h, bow_h):
        def slope(sh):
            t = sh - s0
            if t < 16:
                return lerp(beta_in, beta_h, smoothstep(t / 16))
            if t > C.HIGH_LENGTH - 16:
                return lerp(beta_h, beta_out, smoothstep((t - (C.HIGH_LENGTH - 16)) / 16))
            return beta_h

        def xf(sh):
            return meander_x(mapped(sh)) - bow_h * bow((sh - s0) / C.HIGH_LENGTH)

        def width(sh):
            t = (sh - s0) / C.HIGH_LENGTH
            return lerp(main.value(main.width, s0), C.HIGH_WIDTH, smoothstep(min(t, 1 - t) * 10))
        return Line("HighLine").build(s0, p0, s1, slope, xf, width)

    beta_h = 16.0 * DEG
    bow_h = 50.0
    high = None
    for _ in range(40):
        # the drop: bisect beta for the end's height, then the bow for its z
        lo, hi = 5 * DEG, 30 * DEG
        for _ in range(40):
            beta_h = (lo + hi) / 2
            high = make(beta_h, bow_h)
            if high.y[-1] > p_end[1]:
                lo = beta_h
            else:
                hi = beta_h
        blo, bhi = 0.0, 120.0
        for _ in range(40):
            bow_h = (blo + bhi) / 2
            high = make(beta_h, bow_h)
            if high.z[-1] < p_end[2]:
                blo = bow_h
            else:
                bhi = bow_h
        if abs(high.y[-1] - p_end[1]) < 0.005 and abs(high.z[-1] - p_end[2]) < 0.005:
            break
    high.z_index()
    high.beta = beta_h
    high.bow = bow_h
    high.mapped = mapped
    return main, high, mega


def line_of(name, main, high):
    return high if name == "high" else main


def grid_z0():
    return math.ceil(C.Z_BEFORE / BLK) * BLK


def snapped_frame(line, s, x, yaw_deg=0.0):
    """A jump's frame on the main line (whose heading stays within a few
    degrees of -Z): its axis straight down -Z (turned by yaw) and its lip on
    a grid row, so that the grid's last cell before the lip is the lip's own
    plane and the cell after it the table, the cliff or the gap: the lip is
    exact in ground(), not smeared over a cell. Returns the frame and the
    line's s at the lip."""
    px, _py, pz = line.at(s)
    z0 = grid_z0()
    oz = z0 - round((z0 - pz) / G) * G
    r = line.at_z(oz)
    ox = r[0] + x
    a = yaw_deg * DEG
    fx = -math.sin(a)
    fz = -math.cos(a)
    return (ox, oz, fx, fz, -fz, fx), r[2]


def frame(line, s, x, yaw_deg=0.0):
    """A feature's plan frame: origin, forward (along the line turned by
    yaw, + left) and right."""
    px, _py, pz = line.at(s)
    dx, dz = line.plan_dir(s)
    rx, rz = -dz, dx
    ox = px + rx * x
    oz = pz + rz * x
    a = yaw_deg * DEG
    fx = dx * math.cos(a) + dz * math.sin(a)
    fz = -dx * math.sin(a) + dz * math.cos(a)
    return ox, oz, fx, fz, -fz, fx


# ============================================================================
# the base terrain (the lines' profiles, their sides, noise)
# ============================================================================

class Base:
    def __init__(self, main, high):
        self.lines = [main, high]

    def line_rows(self, z):
        """The lines at z: (x, y, heading (dx, dz), width) for each present."""
        out = []
        for ln in self.lines:
            r = ln.at_z(z)
            if r is not None:
                out.append((r[0], r[1], r[3], r[4]))
        return out

    def height(self, x, z, rows=None):
        if rows is None:
            rows = self.line_rows(z)
        if not rows:
            return None
        num = 0.0
        den = 0.0
        for lx, ly, (dx, dz), w in rows:
            d = (x - lx) * abs(dz)
            e = max(0.0, abs(d) - w / 2)
            h = ly + lateral(e, x, z)
            wt = 1.0 / (e + 0.5) ** 3
            num += h * wt
            den += wt
        return num / den

    def edge_dist(self, x, z, rows=None):
        """Metres beyond the nearest piste edge (0 on a piste)."""
        if rows is None:
            rows = self.line_rows(z)
        best = 1e9
        for lx, ly, (dx, dz), w in rows:
            d = (x - lx) * abs(dz)
            best = min(best, max(0.0, abs(d) - w / 2))
        return best


def lateral(e, x, z):
    if e <= 0:
        return 0.0
    rise = C.SIDE_RISE * e * smoothstep(e / 10.0)
    amp, wl = C.NOISE
    noise = amp * fbm(x, z, wl, C.SEED) * smoothstep((e - 2.0) / 12.0)
    return rise + noise


# ============================================================================
# the features
# ============================================================================

class Overlay:
    """A shape added to the terrain in a feature's frame: a profile along u
    (relative heights, sampled every DU metres) and its lateral fall-off."""
    DU = 0.25

    def __init__(self, fid, kind, frame_, u0, u1, prof, half_w, side, feature=True, lip=None):
        self.id = fid
        self.kind = kind
        self.frame = frame_
        self.u0 = u0
        self.u1 = u1
        self.prof = prof          # list of relative heights from u0 every DU
        self.half_w = half_w
        self.side = side          # metres of height lost per metre beyond half_w
        self.feature = feature    # reported by ground() as a feature footprint
        self.lip = lip            # (u0, u1) of the lip zone

    def at_u(self, u):
        f = (u - self.u0) / self.DU
        i = int(math.floor(f))
        if i < 0 or i >= len(self.prof) - 1:
            return 0.0
        return lerp(self.prof[i], self.prof[i + 1], f - i)

    def uv(self, x, z):
        ox, oz, fx, fz, rx, rz = self.frame
        px = x - ox
        pz = z - oz
        return px * fx + pz * fz, px * rx + pz * rz

    def value(self, x, z):
        u, v = self.uv(x, z)
        if u < self.u0 or u > self.u1:
            return 0.0
        o = self.at_u(u)
        ex = abs(v) - self.half_w
        if ex <= 0:
            return o
        if self.side <= 0:
            return 0.0
        m = abs(o) - self.side * ex
        if m <= 0:
            return 0.0
        return m if o > 0 else -m

    def reach(self):
        """Half the lateral extent the overlay can touch."""
        top = max((abs(p) for p in self.prof), default=0.0)
        return self.half_w + (top / self.side if self.side > 0 else 0.0)

    def bbox(self):
        ox, oz, fx, fz, rx, rz = self.frame
        r = self.reach()
        xs = []
        zs = []
        for u in (self.u0, self.u1):
            for v in (-r, r):
                xs.append(ox + fx * u + rx * v)
                zs.append(oz + fz * u + rz * v)
        return min(xs), max(xs), min(zs), max(zs)


def base_along(base, fr, u):
    ox, oz, fx, fz, _rx, _rz = fr
    return base.height(ox + fx * u, oz + fz * u)


def jump_overlay(base, j, fr):
    """The jump's absolute surface along its axis less the base: its
    overlay. Sets j.profile, j.u0, j.u1."""
    du = Overlay.DU
    beta = -(base_along(base, fr, 1.0) - base_along(base, fr, -1.0)) / 2.0   # base drop per metre (tan)
    y0 = base_along(base, fr, 0.0) + j.h
    tt = math.tan(j.theta)
    m1 = tt + beta
    if j.kind == "drop":
        ramp = min(12.0, 2.5 * j.h / max(m1, 0.05))
    else:
        ramp = max(3.0, min(30.0, 2.5 * j.h / max(m1, 0.05)))
    ua = -3.0 - ramp
    ba = base_along(base, fr, ua)
    ba_d = (base_along(base, fr, ua + 0.5) - base_along(base, fr, ua - 0.5))
    lip_start_y = y0 - 3.0 * tt
    ta = math.tan(j.alpha)
    out_len = 0.0
    if j.kind != "mega":
        ye = y0 + j.yk - ta * (j.xe - j.xk)
        be = base_along(base, fr, j.xe)
        out_len = 8.0 + 1.2 * abs(ye - be)
    ub = j.xe + out_len if j.kind != "mega" else 0.6
    prof = []
    absy = []
    n = int(math.ceil((ub - ua) / du))
    for i in range(n + 1):
        u = ua + i * du
        b = base_along(base, fr, u)
        if u < -3.0:
            t = (u - ua) / ramp
            y = hermite(ba, ba_d * ramp, lip_start_y, tt * ramp, t)
        elif u <= 0.0:
            y = y0 + u * tt
        elif j.kind == "mega":
            y = y0 if u < 0.3 else lerp(y0, b, min(1.0, (u - 0.3) / 0.3))
        elif j.kind == "kicker":
            if u < j.xk - 1.0:
                y = y0 + j.yk
            elif u < j.xk + 1.0:
                # the knuckle, rounded over 2 m
                t = (u - (j.xk - 1.0)) / 2.0
                y = hermite(y0 + j.yk, 0.0, y0 + j.yk - ta, -ta * 2.0, t)
            elif u < j.xe:
                y = y0 + j.yk - ta * (u - j.xk)
            else:
                y = None
        elif j.kind == "drop" and u < DROP_FACE:
            y = lerp(y0, y0 + j.yk, u / DROP_FACE)
        elif j.kind == "drop":
            if u < j.xk - 1.0:
                y = y0 + j.yk
            elif u < j.xk + 1.0:
                t = (u - (j.xk - 1.0)) / 2.0
                y = hermite(y0 + j.yk, 0.0, y0 + j.yk - ta, -ta * 2.0, t)
            elif u < j.xe:
                y = y0 + j.yk - ta * (u - j.xk)
            else:
                y = None
        elif j.kind == "gap":
            front = j.front
            if u < 0.8:
                y = lerp(y0, max(b, y0 - 0.8 * 3), u / 0.8)
                y = max(y, b)
            elif u < j.xk - front:
                y = b
            elif u < j.xk:
                y = lerp(b, y0 + j.yk, (u - (j.xk - front)) / front)
                y = max(y, b)
            elif u < j.xe:
                y = y0 + j.yk - ta * (u - j.xk)
            else:
                y = None
        if y is None:
            # the run-out: from the landing's end back to the base
            ye = y0 + j.yk - ta * (j.xe - j.xk)
            bu = base_along(base, fr, ub)
            bd = base_along(base, fr, ub + 0.5) - base_along(base, fr, ub - 0.5)
            t = (u - j.xe) / out_len
            y = hermite(ye, -ta * out_len, bu, bd * out_len, min(1.0, t))
        prof.append(y - b)
        absy.append(y)
    j.u0 = ua
    j.u1 = ub
    j.y0 = y0
    j.profile = list(zip([ua + i * du for i in range(n + 1)], absy))
    return Overlay(j.id, j.kind, fr, ua, ub, prof, j.width / 2, 1.0, True, (-1.5, 0.0))


def roller_overlay(fid, fr, h, length, width):
    du = Overlay.DU
    n = int(math.ceil(length / du))
    prof = []
    for i in range(n + 1):
        u = -length / 2 + i * du
        t = (u + length / 2) / length
        prof.append(h * 0.5 * (1 - math.cos(2 * math.pi * t)))
    return Overlay(fid, "roller", fr, -length / 2, length / 2, prof, width / 2, 0.35)


def ravine_overlay(mega, fr):
    j = mega.j
    depth = C.MEGA["ravine_depth"]
    du = Overlay.DU
    u0, u1 = 0.3, j.xk - 0.3
    n = int(math.ceil((u1 - u0) / du))
    prof = []
    for i in range(n + 1):
        u = u0 + i * du
        a = smoothstep((u - u0) / 1.5)
        b = smoothstep((u1 - u) / 7.0)
        prof.append(-depth * min(a, b))
    return Overlay("RAVINE", "ravine", fr, u0, u1, prof, 2000.0, 0.0, False)


def ramp_overlay(fid, fr, h):
    """A packed-snow approach ramp up to a rail's start (u = 0)."""
    du = Overlay.DU
    u0, u1 = -4.0, -0.3
    n = int(math.ceil((u1 - u0) / du))
    prof = [max(0.0, h) * smoothstep(i * du / (u1 - u0)) for i in range(n + 1)]
    return Overlay(fid, "ramp", fr, u0, u1, prof, 1.0, 1.0, False)


class Features:
    def __init__(self, main, high, mega, base):
        self.jumps = []
        self.overlays = []
        self.mega = mega
        for fid, ln, s, x, h, length, width in C.ROLLERS:
            line = line_of(ln, main, high)
            fr = frame(line, s, x)
            o = roller_overlay(fid, fr, h, length, width)
            o.line = ln
            o.s = s
            o.x = x
            o.h = h
            self.overlays.append(o)
        for fid, ln, s, x, h, th, al, v, air, w, yaw in C.KICKERS:
            line = line_of(ln, main, high)
            if ln == "main":
                fr, s = snapped_frame(line, s, x, yaw)
            else:
                fr = frame(line, s, x, yaw)
            j = Jump(fid, "kicker", ln, s, x, h, th * DEG, al * DEG, v, w, yaw)
            design_kicker(j, air)
            evaluate(j)
            o = jump_overlay(base, j, fr)
            o.jump = j
            self.jumps.append(j)
            self.overlays.append(o)
        for fid, ln, s, x, step, al, v, w in C.DROPS:
            line = line_of(ln, main, high)
            beta = line.value(line.slope, s)
            fr = frame(line, s, x)
            j = Jump(fid, "drop", ln, s, x, 0.4 * step, -(beta - 5 * DEG), al * DEG, v, w)
            j.yk = -step
            design_drop(j)
            evaluate(j)
            o = jump_overlay(base, j, fr)
            o.jump = j
            self.jumps.append(j)
            self.overlays.append(o)
        hg = C.HG
        line = line_of(hg["line"], main, high)
        fr = frame(line, hg["s"], hg["x"])
        j = Jump(hg["id"], "gap", hg["line"], hg["s"], hg["x"], hg["lip_h"], hg["lip_deg"] * DEG,
                 hg["land_deg"] * DEG, hg["v"], hg["width"])
        j.xk = hg["knuckle"]
        j.yk = hg["knuckle_y"]
        j.front = 5.0
        evaluate(j)
        o = jump_overlay(base, j, fr)
        o.jump = j
        self.hg = j
        self.hg_frame = fr
        self.jumps.append(j)
        self.overlays.append(o)
        # the mega-jump: its ramp and lip, and the ravine
        mj = mega.j
        fr, _s = snapped_frame(main, mj.s, mj.x)
        o = jump_overlay(base, mj, fr)
        o.jump = mj
        self.mega_frame = fr
        self.jumps.append(mj)
        self.overlays.append(o)
        self.overlays.append(ravine_overlay(mega, fr))
        # the approach ramps of the rails higher than 0.4 m
        for row in C.RAILS:
            fid, ln, s, x, kind, segs, h0, w = row
            if h0 > 0.4:
                line = line_of(ln, main, high)
                self.overlays.append(ramp_overlay(fid + "_ramp", frame(line, s, x), h0 - 0.15))
        # the station's roof (HG): rideable, ground() reports it
        st = hg["station"]
        ox, oz, fx, fz, rx, rz = self.hg_frame
        self.roof = dict(frame=self.hg_frame, u0=st["u0"], u1=st["u1"], half_w=st["half_width"],
                         top=self.hg.y0 - 2.0, height=st["height"])


# ============================================================================
# the terrain grid
# ============================================================================

class Grid:
    """The fine grid: rows every G metres down from Z0, columns every G from
    X0 (global), each row holding a run of columns; blocks of BLOCK x BLOCK
    cells are fine (rendered at G) or coarse (rendered as two triangles; their
    nodes on the coarse planes)."""

    def __init__(self, main, high, base, feats):
        self.main = main
        self.high = high
        self.base = base
        self.feats = feats
        z_top = C.Z_BEFORE
        z_bot = main.z[-1] - 12.0
        self.Z0 = math.ceil(z_top / BLK) * BLK
        self.brows = int(math.ceil((self.Z0 - z_bot) / BLK))
        self.rows = self.brows * C.BLOCK + 1
        self.X0 = -600.0
        # each block row's columns (in blocks)
        self.bcols = []
        for br in range(self.brows):
            lo = 1e9
            hi = -1e9
            for k in range(5):
                z = self.Z0 - (br + k / 4.0) * BLK
                rows = base.line_rows(max(min(z, main.z[0]), main.z[-1]))
                for lx, ly, (dx, dz), w in rows:
                    lo = min(lo, lx - w / 2 - C.BAND)
                    hi = max(hi, lx + w / 2 + C.BAND)
            self.bcols.append((int(math.floor((lo - self.X0) / BLK)), int(math.ceil((hi - self.X0) / BLK))))
        # each row's column range (nodes)
        self.c0 = []
        self.c1 = []
        for r in range(self.rows):
            br_a = min(r // C.BLOCK, self.brows - 1)
            ranges = [self.bcols[br_a]]
            if r % C.BLOCK == 0 and r > 0:
                ranges.append(self.bcols[r // C.BLOCK - 1])
            if r == self.rows - 1:
                ranges = [self.bcols[self.brows - 1]]
            a = min(x[0] for x in ranges) * C.BLOCK
            b = max(x[1] for x in ranges) * C.BLOCK
            self.c0.append(a)
            self.c1.append(b)    # inclusive
        self.h = [None] * self.rows
        self.raw()
        self.classify()
        self.coarsen()

    def x_of(self, c):
        return self.X0 + c * G

    def z_of(self, r):
        return self.Z0 - r * G

    def raw(self):
        base = self.base
        main_z = (self.main.z[0], self.main.z[-1])
        # per-row base heights
        for r in range(self.rows):
            z = self.z_of(r)
            zq = max(min(z, main_z[0]), main_z[-1])
            rows = base.line_rows(zq)
            hs = []
            for c in range(self.c0[r], self.c1[r] + 1):
                hs.append(base.height(self.x_of(c), zq, rows))
            self.h[r] = hs
        # the overlays, each on the nodes of its box
        self.ov_nodes = {}
        pos = {}
        neg = {}
        for o in self.feats.overlays:
            x0, x1, z0, z1 = o.bbox()
            r0 = max(0, int(math.floor((self.Z0 - z1) / G)))
            r1 = min(self.rows - 1, int(math.ceil((self.Z0 - z0) / G)))
            touched = set()
            for r in range(r0, r1 + 1):
                z = self.z_of(r)
                ca = max(self.c0[r], int(math.floor((x0 - self.X0) / G)))
                cb = min(self.c1[r], int(math.ceil((x1 - self.X0) / G)))
                for c in range(ca, cb + 1):
                    v = o.value(self.x_of(c), z)
                    if v != 0.0:
                        # overlapping features: the higher build-up, the
                        # deeper cut (two piles of snow merge, not stack)
                        k = (r, c)
                        if v > 0:
                            pos[k] = max(pos.get(k, 0.0), v)
                        else:
                            neg[k] = min(neg.get(k, 0.0), v)
                        touched.add(k)
            self.ov_nodes[o.id] = touched
        for (r, c), v in pos.items():
            self.h[r][c - self.c0[r]] += v
        for (r, c), v in neg.items():
            self.h[r][c - self.c0[r]] += v
        self.lake()
        # quantise to the centimetre, as course_data.as stores them
        self.row_y = []
        for r in range(self.rows):
            ref = round(sum(self.h[r]) / len(self.h[r]), 2)
            self.row_y.append(ref)
            self.h[r] = [ref + round((v - ref) * 100) / 100.0 for v in self.h[r]]

    def lake(self):
        L = C.LAKE
        fr = frame(self.main, L["s"], L["x"])
        self.lake_frame = fr
        a = L["length"] / 2      # along
        b = L["width"] / 2       # across
        ox, oz, fx, fz, rx, rz = fr
        level = None
        nodes = []
        r0 = int((self.Z0 - (oz + a + 12)) / G)
        r1 = int((self.Z0 - (oz - a - 12)) / G) + 1
        for r in range(max(0, r0), min(self.rows, r1 + 1)):
            z = self.z_of(r)
            for c in range(self.c0[r], self.c1[r] + 1):
                x = self.x_of(c)
                u = (x - ox) * fx + (z - oz) * fz
                v = (x - ox) * rx + (z - oz) * rz
                q = math.sqrt((u / a) ** 2 + (v / b) ** 2)
                nodes.append((r, c, q))
        ins = [self.h[r][c - self.c0[r]] for r, c, q in nodes if q <= 1.0]
        level = sum(ins) / len(ins) - 0.6
        self.lake_level = level
        for r, c, q in nodes:
            i = c - self.c0[r]
            if q <= 1.0:
                self.h[r][i] = level
            elif q < 1.0 + 10.0 / min(a, b):
                t = smoothstep((q - 1.0) / (10.0 / min(a, b)))
                self.h[r][i] = lerp(level + 0.3, self.h[r][i], t)
        self.lake_ab = (a, b)

    def node(self, r, c):
        return self.h[r][c - self.c0[r]]

    def has(self, r, c):
        return 0 <= r < self.rows and self.c0[r] <= c <= self.c1[r]

    def in_lake(self, x, z):
        ox, oz, fx, fz, rx, rz = self.lake_frame
        a, b = self.lake_ab
        u = (x - ox) * fx + (z - oz) * fz
        v = (x - ox) * rx + (z - oz) * rz
        return (u / a) ** 2 + (v / b) ** 2 <= 1.0

    def classify(self):
        """Each block: coarse when it is powder far from every piste edge,
        feature and the lake, and not steep."""
        touched = set()
        for nodes in self.ov_nodes.values():
            for r, c in nodes:
                touched.add((r // C.BLOCK, c // C.BLOCK))
        self.coarse = set()
        for br in range(self.brows):
            ca, cb = self.bcols[br]
            r = br * C.BLOCK
            for bc in range(ca, cb):
                c = bc * C.BLOCK
                if (br, bc) in touched:
                    continue
                ok = True
                for dr in range(5):
                    z = self.z_of(r + dr)
                    zq = max(min(z, self.main.z[0]), self.main.z[-1])
                    rows = self.base.line_rows(zq)
                    for dc in range(5):
                        x = self.x_of(c + dc)
                        if self.base.edge_dist(x, zq, rows) < C.FINE_MARGIN or self.in_lake(x, z):
                            ok = False
                if ok:
                    self.coarse.add((br, bc))

    def coarsen(self):
        """Every node of a coarse block (its corners kept) put on the block's
        two triangles."""
        for br, bc in sorted(self.coarse):
            r = br * C.BLOCK
            c = bc * C.BLOCK
            A = self.node(r, c)
            B = self.node(r, c + 4)
            Cc = self.node(r + 4, c + 4)
            D = self.node(r + 4, c)
            for i in range(5):
                for k in range(5):
                    if (i, k) in ((0, 0), (0, 4), (4, 4), (4, 0)):
                        continue
                    fi = i / 4.0
                    fk = k / 4.0
                    if fk >= fi:
                        v = A + (B - A) * fk + (Cc - B) * fi
                    else:
                        v = A + (D - A) * fi + (Cc - D) * fk
                    rr = r + i
                    cc = c + k
                    self.h[rr][cc - self.c0[rr]] = round(v * 100) / 100.0

    # --- ground(), as course_api.as computes it --------------------------------
    def ground(self, x, z):
        fr = (self.Z0 - z) / G
        fc = (x - self.X0) / G
        r = int(math.floor(fr))
        c = int(math.floor(fc))
        if not (self.has(r, c) and self.has(r, c + 1) and self.has(r + 1, c) and self.has(r + 1, c + 1)):
            return None
        h00 = self.node(r, c)
        h01 = self.node(r, c + 1)
        h10 = self.node(r + 1, c)
        h11 = self.node(r + 1, c + 1)
        tx = fc - c
        ty = fr - r
        if tx >= ty:
            y = h00 + (h01 - h00) * tx + (h11 - h01) * ty
            dc = h01 - h00
            dr = h11 - h01
        else:
            y = h00 + (h10 - h00) * ty + (h11 - h10) * tx
            dr = h10 - h00
            dc = h11 - h10
        gx = dc / G
        gz = -dr / G
        n = math.sqrt(gx * gx + 1 + gz * gz)
        return y, (-gx / n, 1 / n, -gz / n)

    def piste_rows(self):
        """Each row's piste intervals (up to two)."""
        out = []
        for r in range(self.rows):
            z = self.z_of(r)
            zq = max(min(z, self.main.z[0]), self.main.z[-1])
            iv = []
            for lx, ly, (dx, dz), w in self.base.line_rows(zq):
                half = w / 2 / max(abs(dz), 0.2)
                iv.append((lx - half, lx + half))
            iv.sort()
            while len(iv) < 2:
                iv.append((1e6, -1e6))
            out.append(iv[:2])
        return out
