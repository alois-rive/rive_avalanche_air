"""The terrain's render meshes from the grid (world/course/terrain.rmdlcmd):
tiles of TILE_BLOCKS block rows, one object a tile and material; fine
blocks at the grid's 1.5 m, coarse blocks as their two triangles (fanned
from their centre where a fine neighbour shares an edge, so that no edge
has a T-junction); the far mountainsides beyond the band."""
import math

import course as C
from build import BLK, G
from meshes import Mesh
from samples import ROCK_NY

PACKED_KINDS = ("kicker", "drop", "gap", "mega", "ramp")


def tri_normal_y(a, b, c):
    ux, uy, uz = b[0] - a[0], b[1] - a[1], b[2] - a[2]
    vx, vy, vz = c[0] - a[0], c[1] - a[1], c[2] - a[2]
    nx = uy * vz - uz * vy
    ny = uz * vx - ux * vz
    nz = ux * vy - uy * vx
    n = math.sqrt(nx * nx + ny * ny + nz * nz) or 1.0
    return ny / n


def build(data):
    g = data.grid
    packed = set()
    for o in data.feats.overlays:
        if o.kind in PACKED_KINDS:
            packed |= g.ov_nodes.get(o.id, set())
    tiles = {}

    def mesh(t, mat):
        key = (t, mat)
        m = tiles.get(key)
        if m is None:
            m = Mesh("T%02d_%s" % (t, mat), mat)
            tiles[key] = m
        return m

    def P(r, c):
        return (g.x_of(c), g.node(r, c), g.z_of(r))

    def uv(p):
        return (p[0], -p[2])

    def tri(t, a, b, c, mat):
        m = mesh(t, mat)
        m.face([a, b, c], [uv(a), uv(b), uv(c)], True)

    def classify(r, c, pts, nodes):
        cx = sum(p[0] for p in pts) / 3
        cz = sum(p[2] for p in pts) / 3
        if g.in_lake(cx, cz):
            return "ice"
        if tri_normal_y(*pts) < ROCK_NY:
            return "rock"
        if all(n in packed for n in nodes):
            return "packed"
        if data.in_piste(cx, cz):
            return "groomed"
        return "powder"

    nb = C.BLOCK
    for br in range(g.brows):
        t = br // C.TILE_BLOCKS
        ca, cb = g.bcols[br]
        for bc in range(ca, cb):
            r0 = br * nb
            c0 = bc * nb
            if (br, bc) in g.coarse:
                A = P(r0, c0)
                B = P(r0, c0 + nb)
                Cc = P(r0 + nb, c0 + nb)
                D = P(r0 + nb, c0)

                def fine(br2, bc2):
                    return 0 <= br2 < g.brows and g.bcols[br2][0] <= bc2 < g.bcols[br2][1] and (br2, bc2) not in g.coarse

                top = [P(r0, c0 + k) for k in range(1, nb)] if fine(br - 1, bc) else []
                right = [P(r0 + k, c0 + nb) for k in range(1, nb)] if fine(br, bc + 1) else []
                bottom = [P(r0 + nb, c0 + nb - k) for k in range(1, nb)] if fine(br + 1, bc) else []
                left = [P(r0 + nb - k, c0) for k in range(1, nb)] if fine(br, bc - 1) else []
                for poly in ([A] + top + [B] + right + [Cc], [A, Cc] + bottom + [D] + left):
                    mat = "rock" if tri_normal_y(poly[0], poly[len(poly) // 2], poly[-1]) < ROCK_NY else "powder"
                    if len(poly) == 3:
                        tri(t, poly[0], poly[1], poly[2], mat)
                    else:
                        # fan from the centre of the triangle (on its plane)
                        a, b, c = poly[0], poly[len(poly) // 2], poly[-1]
                        corners = [poly[0]]
                        # the triangle's three corners are A, B/C, ... : take the
                        # plane of the first, the last and the corner between
                        cx = (A[0] + Cc[0] + (B[0] if poly[-1] is Cc else D[0])) / 3
                        cz = (A[2] + Cc[2] + (B[2] if poly[-1] is Cc else D[2])) / 3
                        cy = (A[1] + Cc[1] + (B[1] if poly[-1] is Cc else D[1])) / 3
                        G_ = (cx, cy, cz)
                        loop = poly + [poly[0]] if poly[-1] is Cc else poly + [poly[0]]
                        for k in range(len(poly)):
                            p1 = poly[k]
                            p2 = poly[(k + 1) % len(poly)]
                            tri(t, G_, p1, p2, mat)
                continue
            for i in range(nb):
                r = r0 + i
                for k in range(nb):
                    c = c0 + k
                    p00 = P(r, c)
                    p01 = P(r, c + 1)
                    p10 = P(r + 1, c)
                    p11 = P(r + 1, c + 1)
                    ta = (p00, p01, p11)
                    tb = (p00, p11, p10)
                    tri(t, *ta, classify(r, c, ta, ((r, c), (r, c + 1), (r + 1, c + 1))))
                    tri(t, *tb, classify(r, c, tb, ((r, c), (r + 1, c + 1), (r + 1, c))))
    out = [tiles[k] for k in sorted(tiles)]
    out += far_meshes(data)
    return out


def far_meshes(data):
    """The mountainsides beyond the band, every FAR_STEP metres outwards,
    starting 6 m under the band's edge and 0.4 m below it."""
    g = data.grid
    base = data.base
    meshes = {}
    nb = C.BLOCK
    cols = int(C.FAR_WIDTH / C.FAR_STEP)

    def height(x, z, e_extra):
        zq = max(min(z, data.main.z[0]), data.main.z[-1])
        h = base.height(x, zq)
        return h + 0.18 * e_extra * min(1.0, e_extra / 60.0) - 0.4

    for br in range(0, g.brows, 2):
        t = br // C.TILE_BLOCKS
        br2 = min(br + 2, g.brows)
        ca = min(g.bcols[k][0] for k in range(br, br2))
        cb = max(g.bcols[k][1] for k in range(br, br2))
        za = g.z_of(br * nb)
        zb = g.z_of(br2 * nb)
        m = meshes.get(t)
        if m is None:
            m = Mesh("T%02d_far" % t, "far")
            meshes[t] = m
        for side in (-1, 1):
            x_edge = g.x_of((ca if side < 0 else cb) * nb)
            xs = [x_edge - side * BLK] + [x_edge + side * C.FAR_STEP * k for k in range(0, cols + 1)]
            xs = [xs[0]] + xs[1:]
            for k in range(len(xs) - 1):
                xa, xb = xs[k], xs[k + 1]
                ea = max(0.0, (xa - x_edge) * side)
                eb = max(0.0, (xb - x_edge) * side)
                pa0 = (xa, height(xa, za, ea), za)
                pb0 = (xb, height(xb, za, eb), za)
                pa1 = (xa, height(xa, zb, ea), zb)
                pb1 = (xb, height(xb, zb, eb), zb)
                if side > 0:
                    quad = [pa0, pb0, pb1, pa1]
                else:
                    quad = [pb0, pa0, pa1, pb1]
                m.face(quad[:3], [(p[0] / 4, -p[2] / 4) for p in quad[:3]], True)
                m.face([quad[0], quad[2], quad[3]], [(p[0] / 4, -p[2] / 4) for p in (quad[0], quad[2], quad[3])], True)
    return [meshes[k] for k in sorted(meshes)]
