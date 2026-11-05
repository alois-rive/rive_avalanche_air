"""The course's geometry from course.py: the lines, the jumps, the terrain's
height function. Standard library only; deterministic.

Coordinates: x right, y up, z towards the start (the course runs down -z).
A line is sampled every LINE_DS metres of its s (its base profile's arc
length); `plan` is the horizontal distance along it.
"""
import math
import struct

import course as C

LINE_DS = 0.25
DEG = math.pi / 180.0


def f32(x):
    return struct.unpack("<f", struct.pack("<f", x))[0]


def smoothstep(t):
    t = 0.0 if t < 0 else 1.0 if t > 1 else t
    return t * t * (3 - 2 * t)


def lerp(a, b, t):
    return a + (b - a) * t


def hermite(p0, m0, p1, m1, t):
    t2 = t * t
    t3 = t2 * t
    return (2 * t3 - 3 * t2 + 1) * p0 + (t3 - 2 * t2 + t) * m0 + (-2 * t3 + 3 * t2) * p1 + (t3 - t2) * m1


def hermite_d(p0, m0, p1, m1, t):
    t2 = t * t
    return (6 * t2 - 6 * t) * p0 + (3 * t2 - 4 * t + 1) * m0 + (-6 * t2 + 6 * t) * p1 + (3 * t2 - 2 * t) * m1


# --- value noise (seeded, smooth) ---------------------------------------------

def _hash(ix, iz, seed):
    h = (ix * 374761393 + iz * 668265263 + seed * 2246822519) & 0xFFFFFFFF
    h = ((h ^ (h >> 13)) * 1274126177) & 0xFFFFFFFF
    h ^= h >> 16
    return (h & 0xFFFFFF) / float(0xFFFFFF)


def value_noise(x, z, wavelength, seed):
    fx = x / wavelength
    fz = z / wavelength
    ix = math.floor(fx)
    iz = math.floor(fz)
    tx = smoothstep(fx - ix)
    tz = smoothstep(fz - iz)
    a = _hash(ix, iz, seed)
    b = _hash(ix + 1, iz, seed)
    c = _hash(ix, iz + 1, seed)
    d = _hash(ix + 1, iz + 1, seed)
    return lerp(lerp(a, b, tx), lerp(c, d, tx), tz) * 2 - 1


def fbm(x, z, wavelength, seed):
    return 0.65 * value_noise(x, z, wavelength, seed) + 0.35 * value_noise(x, z, wavelength * 0.45, seed + 7)


# --- the base profile -----------------------------------------------------------

def held_blended(knots, s, blends, default_blend):
    """A value held from knot to knot, blended (smoothstep) over each knot's
    blend width."""
    v = knots[0][1]
    for i in range(1, len(knots)):
        k, val = knots[i]
        b = blends.get(k, default_blend)
        prev = knots[i - 1][1]
        if s <= k - b / 2:
            return v
        if s < k + b / 2:
            return lerp(prev, val, smoothstep((s - (k - b / 2)) / b))
        v = val
    return v


def meander_x(s):
    k = C.MEANDER
    if s <= k[0][0]:
        return k[0][1]
    for i in range(1, len(k)):
        if s <= k[i][0]:
            t = (s - k[i - 1][0]) / (k[i][0] - k[i - 1][0])
            return lerp(k[i - 1][1], k[i][1], (1 - math.cos(math.pi * t)) / 2)
    return k[-1][1]


def bow(t):
    """0 at both ends, 1 in the middle, flat at the ends."""
    return math.sin(math.pi * t) ** 2


class Line:
    """A line sampled every LINE_DS metres: s, x, y (base), z, slope, width,
    and the derived plan distance."""

    def __init__(self, name):
        self.name = name
        self.s = []
        self.x = []
        self.y = []
        self.z = []
        self.slope = []    # radians, positive downhill
        self.width = []

    def build(self, s0, p0, s_end, slope_fn, x_fn, width_fn):
        """Integrate from (s0, p0 = (x, y, z)) to s_end."""
        x, y, z = p0
        n = int(round((s_end - s0) / LINE_DS))
        for i in range(n + 1):
            s = s0 + i * LINE_DS
            beta = slope_fn(s)
            self.s.append(s)
            self.x.append(x)
            self.y.append(y)
            self.z.append(z)
            self.slope.append(beta)
            self.width.append(width_fn(s))
            if i == n:
                break
            # step to the next sample with the slope at the middle
            sm = s + LINE_DS / 2
            bm = slope_fn(sm)
            dp = math.cos(bm) * LINE_DS
            dx = x_fn(s + LINE_DS) - x_fn(s)
            if abs(dx) >= dp:
                raise ValueError("%s: lateral change too steep at s=%.1f" % (self.name, s))
            dz = math.sqrt(dp * dp - dx * dx)
            x += dx
            y -= math.sin(bm) * LINE_DS
            z -= dz
        return self

    def index(self, s):
        return (s - self.s[0]) / LINE_DS

    def at(self, s):
        """(x, y, z) of the base line at s, interpolated."""
        f = self.index(s)
        i = int(math.floor(f))
        i = max(0, min(len(self.s) - 2, i))
        t = f - i
        return (lerp(self.x[i], self.x[i + 1], t), lerp(self.y[i], self.y[i + 1], t), lerp(self.z[i], self.z[i + 1], t))

    def value(self, arr, s):
        f = self.index(s)
        i = int(math.floor(f))
        i = max(0, min(len(self.s) - 2, i))
        t = f - i
        return lerp(arr[i], arr[i + 1], t)

    def tangent(self, s):
        """The unit 3D tangent, downhill."""
        a = self.at(s - 0.5)
        b = self.at(s + 0.5)
        d = (b[0] - a[0], b[1] - a[1], b[2] - a[2])
        n = math.sqrt(d[0] ** 2 + d[1] ** 2 + d[2] ** 2)
        return (d[0] / n, d[1] / n, d[2] / n)

    def plan_dir(self, s):
        """The unit plan direction (dx, dz), downhill."""
        a = self.at(s - 0.5)
        b = self.at(s + 0.5)
        dx = b[0] - a[0]
        dz = b[2] - a[2]
        n = math.hypot(dx, dz)
        return (dx / n, dz / n)

    def z_index(self):
        """For lookups by z: the line's z is strictly decreasing."""
        for i in range(1, len(self.z)):
            if not self.z[i] < self.z[i - 1]:
                raise ValueError("%s: z does not decrease at s=%.1f" % (self.name, self.s[i]))

    def at_z(self, z):
        """(x, y, s, plan heading (dx, dz)) where the line crosses z, or None
        outside its z range."""
        zs = self.z
        if z > zs[0] or z < zs[-1]:
            return None
        lo, hi = 0, len(zs) - 1
        while hi - lo > 1:
            mid = (lo + hi) // 2
            if zs[mid] >= z:
                lo = mid
            else:
                hi = mid
        t = (zs[lo] - z) / (zs[lo] - zs[hi]) if zs[lo] != zs[hi] else 0.0
        x = lerp(self.x[lo], self.x[hi], t)
        y = lerp(self.y[lo], self.y[hi], t)
        s = lerp(self.s[lo], self.s[hi], t)
        dx = self.x[hi] - self.x[lo]
        dz = self.z[hi] - self.z[lo]
        n = math.hypot(dx, dz)
        return x, y, s, (dx / n, dz / n), lerp(self.width[lo], self.width[hi], t)


def section_of(s):
    for sec in C.SECTIONS:
        if s < sec[3]:
            return sec
    return C.SECTIONS[-1]


def section_width(s):
    """The piste's width along the main line, eased between sections."""
    w = C.SECTIONS[0][4]
    for i in range(1, len(C.SECTIONS)):
        s0 = C.SECTIONS[i][2]
        if s < s0 - 10:
            return w
        if s < s0 + 10:
            return lerp(w, C.SECTIONS[i][4], smoothstep((s - (s0 - 10)) / 20))
        w = C.SECTIONS[i][4]
    return w


# --- the jumps -----------------------------------------------------------------

def flight(v, theta, t):
    vx = v * math.cos(theta)
    vy = v * math.sin(theta)
    return vx * t, vy * t - 0.5 * C.AIR_GRAVITY * t * t


def fly_onto(v, theta, surface, u_max=200.0, dt=0.002):
    """Fly from the lip (0, 0) at v and theta onto `surface(u)` (heights
    relative to the lip, None where there is none): (t, u, y, impact,
    flight angle) at the first touch, or None."""
    vx = v * math.cos(theta)
    vy = v * math.sin(theta)
    t = dt
    while t < 8:
        u = vx * t
        y = vy * t - 0.5 * C.AIR_GRAVITY * t * t
        if u > u_max:
            return None
        g = surface(u)
        if g is not None and y <= g[0]:
            fvy = vy - C.AIR_GRAVITY * t
            spd = math.hypot(vx, fvy)
            # the surface's slope there
            slope = g[1]
            ang = math.atan2(-fvy, vx)
            surf = math.atan(-slope)
            impact = spd * math.sin(ang - surf)
            return t, u, y, impact, ang
        t += dt
    return None


class Jump:
    """A take-off and its landing in the jump's frame: u forward along the
    jump's axis from the lip's edge, heights relative to the lip's top.

    kind: kicker | drop | gap | mega. The take-off ramp rises from the base
    over `ramp` metres, its last 3 m straight at the lip angle; past the lip
    the table (kicker), a cliff (drop), the base terrain (gap) or the ravine
    (mega), then the knuckle at (xk, yk), the landing at `alpha` and the
    run-out back to the base."""

    def __init__(self, fid, kind, line, s, x, h, theta, alpha, v, width, yaw=0.0):
        self.id = fid
        self.kind = kind
        self.line = line
        self.s = s
        self.x = x
        self.h = h
        self.theta = theta
        self.alpha = alpha
        self.v = v
        self.width = width
        self.yaw = yaw
        self.air = 0.0
        self.xk = 0.0
        self.yk = 0.0
        self.xe = 0.0
        self.profile = []   # (u, absolute y) from the ramp's start to the run-out's end
        self.u0 = 0.0
        self.u1 = 0.0
        self.report = {}

    def landing(self, u):
        """The landing's height and slope (dy/du) at u relative to the lip,
        or None in the gap before the knuckle."""
        if self.kind in ("kicker", "drop") and u < self.xk:
            if u < (0.0 if self.kind == "kicker" else DROP_FACE):
                return None
            return (self.yk, 0.0)
        if u < self.xk:
            return None
        return (self.yk - math.tan(self.alpha) * (u - self.xk), -math.tan(self.alpha))


def design_kicker(j, air):
    """The knuckle where the landing line through the design flight's point
    at `air` seconds meets the lip's height. The landing is at most 4 degrees
    shallower than the flight there, so that the flight meets it first at
    that point (a straight landing tangent to the flight would stand above
    it before): COURSE.md's landing angle is the steepest it may be."""
    xs, ys = flight(j.v, j.theta, air)
    vx = j.v * math.cos(j.theta)
    vy = j.v * math.sin(j.theta) - C.AIR_GRAVITY * air
    phi = math.atan2(-vy, vx)
    alpha = min(j.alpha, phi - 4 * DEG)
    j.yk = 0.0
    for _ in range(30):
        j.alpha = alpha
        j.xk = xs + ys / math.tan(alpha)
        r = fly_onto(j.v, j.theta, j.landing)
        if r is not None and abs(r[0] - air) < 0.03:
            return
        alpha -= 0.5 * DEG


DROP_FACE = 1.2     # a drop's cliff face, metres from its edge


def design_drop(j):
    """A drop: the cliff face, a deck at its foot, the knuckle where the
    landing line through the design flight's point 1 m below the foot meets
    the deck, the landing at most 4 degrees shallower than the flight there
    (and no steeper than the table's angle)."""
    vx = j.v * math.cos(j.theta)
    vy0 = j.v * math.sin(j.theta)
    target = j.yk - 1.0
    a = 0.5 * C.AIR_GRAVITY
    t = (vy0 + math.sqrt(vy0 * vy0 + 4 * a * -target)) / (2 * a)
    xs = vx * t
    phi = math.atan2(-(vy0 - C.AIR_GRAVITY * t), vx)
    alpha = min(j.alpha, phi - 4 * DEG)
    for _ in range(30):
        j.alpha = alpha
        j.xk = max(DROP_FACE + 1.0, xs - 1.0 / math.tan(alpha))
        r = fly_onto(j.v, j.theta, j.landing)
        if r is not None and abs(r[1] - xs) < 0.6:
            return
        alpha -= 0.5 * DEG


def design_landing(j, impact):
    """For a landing from a fixed knuckle (a drop, a gap): the landing angle
    whose design flight lands with `impact` m/s into the slope."""
    best = None
    for k in range(0, 61):
        j.alpha = (12.0 + 0.5 * k) * DEG
        r = fly_onto(j.v, j.theta, j.landing)
        if r is None:
            continue
        score = abs(r[3] - impact)
        if best is None or score < best[0] - 1e-9:
            best = (score, j.alpha)
    j.alpha = best[1]


def evaluate(j):
    """Fly the design speed and +-3 m/s onto the landing; set j.air, the
    landing's end and the report."""
    rows = {}
    for dv in (-3.0, 0.0, 3.0):
        r = fly_onto(j.v + dv, j.theta, j.landing)
        rows[dv] = r
    if rows[0.0] is None:
        raise ValueError("%s: the design flight never lands" % j.id)
    j.air = rows[0.0][0]
    far = rows[3.0][1] if rows[3.0] else rows[0.0][1] + 15
    j.xe = max(far + 3.0, j.xk + 6.0)
    j.report = {dv: (round(r[0], 2), round(r[1], 1), round(r[3], 1)) if r else None for dv, r in rows.items()}
