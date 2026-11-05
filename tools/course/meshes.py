"""Meshes as the course's generators build them, and their .rmdlcmd data
form (Hedra's RMDLCMD.md, section 4): one object a mesh, one material an
object, so that the scene gives each node its ShaderMaterial as its
material_override (the materials the Daylight timeline keys).

Points are scene points (Y up); the data form is Z up as Blender: the
scene's (x, y, z) is the model's (x, -z, y).
"""
import math


def num(x, places=4):
    v = round(x, places)
    if v == 0:
        v = 0.0
    s = ("%." + str(places) + "f") % v
    if "." in s:
        s = s.rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


def to_model(p):
    return (p[0], -p[2], p[1])


class Mesh:
    """Faces over vertices, each face its corners' UVs. `smooth` faces share
    their vertices' normals (Gouraud across them); flat faces do not."""

    def __init__(self, name, material):
        self.name = name
        self.material = material
        self.verts = []
        self.index = {}
        self.faces = []      # (vertex ids, uvs, smooth)

    def vert(self, p, key=None):
        if key is not None:
            k = key
        else:
            k = (round(p[0], 4), round(p[1], 4), round(p[2], 4))
        i = self.index.get(k)
        if i is None:
            i = len(self.verts)
            self.verts.append(p)
            self.index[k] = i
        return i

    def face(self, pts, uvs, smooth=True):
        ids = [self.vert(p) for p in pts]
        # drop repeated corners (a degenerate face)
        if len(set(ids)) < 3:
            return
        self.faces.append((ids, uvs, smooth))

    def tris(self):
        return sum(len(f[0]) - 2 for f in self.faces)

    def extend(self, other):
        for ids, uvs, smooth in other.faces:
            self.face([other.verts[i] for i in ids], uvs, smooth)


def rmdlcmd(meshes, materials, source):
    """The data form of `meshes`. `materials`: [(name, (r, g, b))] in slot
    order, the colours what a tool draws when the scene's shader cannot."""
    mat_index = {name: i for i, (name, _c) in enumerate(materials)}
    out = ["# rmdlcmd 1", "# data form, written by %s: edit that, then run it" % source]
    out.append("data scene --objects %d --active 0" % len(meshes))
    for i, (name, col) in enumerate(materials):
        out.append('data material %d %s --base-color "%s" --roughness 1' % (i, name, " ".join(num(c) for c in col)))
    for oi, m in enumerate(meshes):
        out.append('data object %d %s --type mesh --material-slots "%d"' % (oi, m.name, mat_index[m.material]))
        co = []
        for p in m.verts:
            co += [num(v) for v in to_model(p)]
        edges = {}
        edge_list = []
        loops = []
        uvs = []
        face_loops = []
        normals = []
        flags = []
        for fi, (ids, fuv, smooth) in enumerate(m.faces):
            face_loops += [str(len(loops)), str(len(ids))]
            for k, v in enumerate(ids):
                w = ids[(k + 1) % len(ids)]
                key = (min(v, w), max(v, w))
                if key not in edges:
                    edges[key] = len(edge_list)
                    edge_list.append(key)
                loops.append((v, edges[key], fi))
                # UVs are given in the image's frame (top-left origin, v
                # down); the data form's v is up (the loader flips it back)
                u, vv = fuv[k]
                uvs += ["1", num(u, 5), num(1.0 - vv, 5)]
            nx = ny = nz = 0.0
            for k in range(len(ids)):
                a = to_model(m.verts[ids[k]])
                b = to_model(m.verts[ids[(k + 1) % len(ids)]])
                nx += (a[1] - b[1]) * (a[2] + b[2])
                ny += (a[2] - b[2]) * (a[0] + b[0])
                nz += (a[0] - b[0]) * (a[1] + b[1])
            n = math.sqrt(nx * nx + ny * ny + nz * nz) or 1.0
            normals += [num(nx / n), num(ny / n), num(nz / n)]
            flags.append("1" if smooth else "0")
        out.append(
            'data mesh %d --verts %d --co "%s" --edges %d --edge-verts "%s" --faces %d --face-loops "%s" '
            '--face-normals "%s" --face-flags "%s" --loops %d --loop-refs "%s" --loop-uvs "%s" --uv-layer UVMap'
            % (oi, len(m.verts), " ".join(co), len(edge_list), " ".join("%d %d" % e for e in edge_list),
               len(m.faces), " ".join(face_loops), " ".join(normals), " ".join(flags), len(loops),
               " ".join("%d %d %d" % l for l in loops), " ".join(uvs)))
    return "\n".join(out) + "\n"


# --- primitives (props, features) ----------------------------------------------

def v_add(a, b):
    return (a[0] + b[0], a[1] + b[1], a[2] + b[2])


def v_sub(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def v_scale(a, k):
    return (a[0] * k, a[1] * k, a[2] * k)


def v_cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def v_len(a):
    return math.sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2])


def v_unit(a):
    n = v_len(a) or 1.0
    return (a[0] / n, a[1] / n, a[2] / n)


class Xf:
    """A placement: a yaw (radians, + left: -Z turns towards -X) then a
    translation, and a uniform scale."""

    def __init__(self, pos=(0.0, 0.0, 0.0), yaw=0.0, scale=1.0):
        self.pos = pos
        self.c = math.cos(yaw)
        self.s = math.sin(yaw)
        self.k = scale

    def __call__(self, p):
        x, y, z = p[0] * self.k, p[1] * self.k, p[2] * self.k
        return (x * self.c + z * self.s + self.pos[0], y + self.pos[1], -x * self.s + z * self.c + self.pos[2])


def quad(mesh, a, b, c, d, uv=((0, 1), (1, 1), (1, 0), (0, 0)), smooth=False):
    """a b c d counter-clockwise seen from the front."""
    mesh.face([a, b, c, d], list(uv), smooth)


def box(mesh, xf, x0, x1, y0, y1, z0, z1, uvr=(0, 0, 1, 1), tile=None, faces="all", smooth=False):
    """An axis box in the placement's frame. uvr: the texture page's region
    (u0, v0, u1, v1) every face maps to; tile: metres a repeat (the region
    repeated over the face) instead."""
    P = [xf((x, y, z)) for x in (x0, x1) for y in (y0, y1) for z in (z0, z1)]

    def p(ix, iy, iz):
        return P[ix * 4 + iy * 2 + iz]

    def uvs(w, h):
        u0, v0, u1, v1 = uvr
        if tile:
            return ((u0, v0 + h / tile * (v1 - v0)), (u0 + w / tile * (u1 - u0), v0 + h / tile * (v1 - v0)),
                    (u0 + w / tile * (u1 - u0), v0), (u0, v0))
        return ((u0, v1), (u1, v1), (u1, v0), (u0, v0))
    sx, sy, sz = (x1 - x0) * xf.k, (y1 - y0) * xf.k, (z1 - z0) * xf.k
    sel = faces
    if sel == "all" or "f" in sel:   # +z (front)
        quad(mesh, p(0, 0, 1), p(1, 0, 1), p(1, 1, 1), p(0, 1, 1), uvs(sx, sy), smooth)
    if sel == "all" or "b" in sel:   # -z
        quad(mesh, p(1, 0, 0), p(0, 0, 0), p(0, 1, 0), p(1, 1, 0), uvs(sx, sy), smooth)
    if sel == "all" or "r" in sel:   # +x
        quad(mesh, p(1, 0, 1), p(1, 0, 0), p(1, 1, 0), p(1, 1, 1), uvs(sz, sy), smooth)
    if sel == "all" or "l" in sel:   # -x
        quad(mesh, p(0, 0, 0), p(0, 0, 1), p(0, 1, 1), p(0, 1, 0), uvs(sz, sy), smooth)
    if sel == "all" or "t" in sel:   # +y
        quad(mesh, p(0, 1, 1), p(1, 1, 1), p(1, 1, 0), p(0, 1, 0), uvs(sx, sz), smooth)
    if sel == "all" or "d" in sel:   # -y
        quad(mesh, p(0, 0, 0), p(1, 0, 0), p(1, 0, 1), p(0, 0, 1), uvs(sx, sz), smooth)


def tube(mesh, a, b, radius, sides=6, uvr=(0, 0, 1, 1), smooth=True, caps=False, r1=None):
    """A prism of `sides` sides from scene point a to b."""
    axis = v_sub(b, a)
    length = v_len(axis)
    d = v_unit(axis)
    up = (0.0, 1.0, 0.0) if abs(d[1]) < 0.9 else (1.0, 0.0, 0.0)
    e1 = v_unit(v_cross(d, up))
    e2 = v_cross(e1, d)
    r1 = radius if r1 is None else r1
    ring_a = []
    ring_b = []
    for k in range(sides):
        t = 2 * math.pi * (k + 0.5) / sides
        off = v_add(v_scale(e1, math.cos(t)), v_scale(e2, math.sin(t)))
        ring_a.append(v_add(a, v_scale(off, radius)))
        ring_b.append(v_add(b, v_scale(off, r1)))
    u0, v0, u1, v1 = uvr
    for k in range(sides):
        k2 = (k + 1) % sides
        ua = u0 + (u1 - u0) * k / sides
        ub = u0 + (u1 - u0) * (k + 1) / sides
        mesh.face([ring_a[k], ring_a[k2], ring_b[k2], ring_b[k]], [(ua, v1), (ub, v1), (ub, v0), (ua, v0)], smooth)
    if caps:
        mesh.face(list(reversed(ring_a)), [(0.5, 0.5)] * sides, False)
        if r1 > 0:
            mesh.face(ring_b, [(0.5, 0.5)] * sides, False)
    return length


def cone(mesh, base_center, radius, height, sides=6, uvr=(0, 0, 1, 1), smooth=True):
    apex = (base_center[0], base_center[1] + height, base_center[2])
    pts = []
    for k in range(sides):
        t = 2 * math.pi * (k + 0.5) / sides
        pts.append((base_center[0] + radius * math.cos(t), base_center[1], base_center[2] + radius * math.sin(t)))
    u0, v0, u1, v1 = uvr
    for k in range(sides):
        k2 = (k + 1) % sides
        ua = u0 + (u1 - u0) * k / sides
        ub = u0 + (u1 - u0) * (k + 1) / sides
        mesh.face([pts[k2], pts[k], apex], [(ub, v1), (ua, v1), ((ua + ub) / 2, v0)], smooth)
    mesh.face(pts, [(0.5, 0.5)] * sides, False)
