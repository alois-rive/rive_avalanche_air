"""The texture pages' regions, shared by tools/make_textures.py (which draws
them) and tools/make_props.py (which maps the props' faces onto them).
Each region is (x, y, w, h) in pixels of its page; uv() gives it as UVs
(image frame: origin top left, v down)."""

BUILDING = dict(size=(128, 128), regions=dict(
    planks=(0, 0, 64, 64),        # log-cabin planks, a dark gap every 8 px
    window=(64, 0, 64, 64),       # planks with a lit window (warm at dusk: the emission's tint)
    roof=(0, 64, 64, 32),         # snow on the roof, its edge icicles
    door=(64, 64, 32, 64),        # a door with a sign over it
    metal=(96, 64, 32, 32),       # grey steel, rivets
    concrete=(96, 96, 32, 32),    # the station's base
    timber=(0, 96, 64, 32),       # dark beams
))

LIFT = dict(size=(128, 128), regions=dict(
    steel=(0, 0, 64, 64),         # the pylons: grey-blue steel with a highlight
    seat=(64, 0, 64, 32),         # the chairs: red seats
    cabin=(64, 32, 64, 64),       # the gondola's cabins: red with windows
    cable=(0, 64, 64, 8),         # dark cable
    yellow=(0, 72, 64, 24),       # the pylons' heads, warning stripes
    station=(0, 96, 128, 32),     # the station's sign band
))

BANNERS = dict(size=(256, 256), regions=dict(
    frostbyte=(0, 0, 128, 64), neonpeak=(128, 0, 128, 64),
    avalanche=(0, 64, 128, 64), chillwave=(128, 64, 128, 64),
    pow=(0, 128, 128, 64), radical=(128, 128, 128, 64),
    highline=(0, 192, 128, 64), lowline=(128, 192, 128, 64),
))

ARCHES = dict(size=(256, 256), regions=dict(
    start=(0, 0, 128, 128), split=(128, 0, 128, 128),
    finish=(0, 128, 128, 128), mega=(128, 128, 128, 128),
))

CROWD = dict(size=(128, 64), regions=dict(a=(0, 0, 32, 64), b=(32, 0, 32, 64), c=(64, 0, 32, 64), d=(96, 0, 32, 64)))


def uv(page, name):
    x, y, w, h = page["regions"][name]
    W, H = page["size"]
    return (x / W, y / H, (x + w) / W, (y + h) / H)
