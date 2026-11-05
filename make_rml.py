#!/usr/bin/env python3
"""Writes avalanche.rml: Avalanche Air's Rive side (docs/RIVE.md).

- GameData: the Scene3D's `data` view model, one property per pin of
  tools/pins.py (the world's bindings resolve against it);
- Ui: the Rive side's own data (the strings ui/trick_text.as composes from
  the pins, the grid's scale ui/fit.as writes, the menus' selections);
- Game: the Scene3D's view model (scene, source, playing, ...) with `data`
  and `ui`: the main artboard's;
- Main: the root artboard, the window's size: the Scene3D filling it (always
  present: the title's attract, the run, the results' backdrop), the 2D
  scripts (ui/), and over the 3D the Grid: the overlays, 320 x 240
  artboards drawn at the whole scale ui/fit.as works out (docs/RIVE.md,
  section 7): a Solo of the screens (TitleOverlay, HudOverlay,
  ResultsOverlay, InitialsOverlay) keyed by `phase`, the PauseOverlay by
  `paused`, the Wipe and the Captions. Main's machine holds the keys'
  listeners (keyboard listeners run on the focused artboard, not a nested
  one), the focus (the Scene3D's during the run, a menu's otherwise), the
  pause (the Scene3D's `playing` false) and the demo mode (docs/RIVE.md,
  section 8);
- the overlays, each with its own machine reading Game's data.

The look is 1998's (docs/LOOK.md, section 8): a wide italic techno face
(Saira, italic, width 125, black) for trick names, praise words, grades
and titles, a pixel font (Press Start 2P) for numbers and labels at
whole multiples of its 8 px, white numbers with a black outline and a
hard shadow, chrome gradients, slanted panels, hot pink / acid green /
orange / cyan on black and deep blue. Both fonts SIL OFL (fonts/).

Ids are client 41 ("41:<n>"); the hedra_engine library's are 93.

    python3 make_rml.py                   # write avalanche.rml
    python3 make_rml.py --check           # exit 1 when it would change
    python3 make_rml.py --preview DIR     # a 2D-only copy (no Scene3D) to iterate on quickly
"""
import os
import shutil
import sys

sys.dont_write_bytecode = True
ROOT = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(ROOT, "tools"))
from pins import PINS  # noqa: E402
from make_ui_lib import (El, Doc, box, changed, f_close, f_fn, f_in, f_op, f_sep, f_val,  # noqa: E402
                         fire, on_keys, semantics, set_value, when, write_from)

CLIENT = 41
SCENE3D = "93:1"
AWAY = -100000   # where a hidden layer is keyed: off the artboard, so it takes no pointer

# ---------------------------------------------------------------------------
# Tokens (docs/LOOK.md, section 8): ARGB
# ---------------------------------------------------------------------------

PINK = "FFF83890"
GREEN = "FFA8F830"
ORANGE = "FFF88818"
CYAN = "FF30D8F8"
WHITE = "FFFFFFFF"
BLACK = "FF000000"
DEEP = "FF0C1448"      # deep blue panels
NAVY = "FF1C2C78"
GOLD = "FFF8D030"
GREY = "FF98A0B0"
DIM = "FF586078"
RED = "FFF82818"
HALF = "80000000"      # the era's 50 % mode
CLEAR = "00000000"

# chrome gradients (sky, a dark horizon line, warm ground, a highlight):
# (position, colour) stops across the glyphs' height
CHROME = [(0.0, "FFFFFFFF"), (0.30, "FF9CD8FF"), (0.48, "FF3868C0"), (0.52, "FF101838"),
          (0.56, "FF8C5028"), (0.78, "FFF8C070"), (1.0, "FFFFF4D8")]
GOLD_CHROME = [(0.0, "FFFFFFF0"), (0.30, "FFF8E070"), (0.48, "FFC08010"), (0.52, "FF402000"),
               (0.56, "FF905010"), (0.78, "FFF8C840"), (1.0, "FFFFFCD8")]
PINK_CHROME = [(0.0, "FFFFFFFF"), (0.30, "FFFFA8D8"), (0.48, "FFE02880"), (0.52, "FF400020"),
               (0.56, "FF902050"), (0.78, "FFF870B0"), (1.0, "FFFFE0F0")]
CYAN_CHROME = [(0.0, "FFFFFFFF"), (0.30, "FFA8F0FF"), (0.48, "FF2898D0"), (0.52, "FF002848"),
               (0.56, "FF185878"), (0.78, "FF60D0F0"), (1.0, "FFE0FFFF")]
GREY_CHROME = [(0.0, "FFFFFFFF"), (0.30, "FFD0D8E0"), (0.48, "FF8890A0"), (0.52, "FF282C38"),
               (0.56, "FF60646C"), (0.78, "FFB8BCC4"), (1.0, "FFF0F0F0")]
GREEN_CHROME = [(0.0, "FFFFFFFF"), (0.30, "FFE0FF98"), (0.48, "FF78C010"), (0.52, "FF203800"),
                (0.56, "FF508010"), (0.78, "FFB8F040"), (1.0, "FFF4FFD8")]

FONT_FILES = [("PressStart2P-Regular.ttf", "pressstart2p_PressStart2P-Regular.ttf"),
              ("OFL-PressStart2P.txt", "pressstart2p_OFL.txt"),
              ("Saira-Italic-VF.ttf", "saira_Saira-Italic[wdth,wght].ttf"),
              ("OFL-Saira.txt", "saira_OFL.txt")]
PIX = "pix"     # Press Start 2P: 8 px design, set at 8 and 16
DISP = "disp"   # Saira Italic, wght 900, wdth 125
TAG_WGHT = 2003265652
TAG_WDTH = 2003072104

GRID_W, GRID_H = 320, 240

# Defaults for the inbound settings (the world reads them on its first frame).
DEFAULTS = {
    "musicVolume": 0.8,
    "sfxVolume": 0.9,
    "voiceVolume": 1.0,
    "landingAssist": True,
    "seed": 1,
    "countdown": -1,
    "captionLine": -1,
    "resGrade": -1,
}

# The pause menu's rows (ui/ui_state.as PAUSE_ROWS is their count):
# (key, label, kind, target)  kind: action, volume (a data number), toggle
PAUSE_ITEMS = [
    ("resume", "RESUME", "action", None),
    ("restart", "RESTART", "action", None),
    ("music", "MUSIC", "volume", ("data", "musicVolume")),
    ("sfx", "EFFECTS", "volume", ("data", "sfxVolume")),
    ("voice", "VOICE", "volume", ("data", "voiceVolume")),
    ("controls", "CONTROLS", "action", None),
    ("assist", "LANDING ASSIST", "toggle", ("data", "landingAssist")),
    ("captions", "CAPTIONS", "toggle", ("ui", "captions")),
    ("motion", "REDUCED MOTION", "toggle", ("data", "reducedMotion")),
    ("contrast", "HIGH CONTRAST", "toggle", ("ui", "highContrast")),
    ("quit", "QUIT TO TITLE", "action", None),
]

# The pause menu's controls card: (action, mapping) per device (docs/SPEC.md, section 3)
CONTROLS_KEYS = [("STEER", "A D"), ("TUCK", "S"), ("OLLIE", "SPACE / E"), ("GRABS", "J K L J+K"),
                 ("SPIN", "LEFT RIGHT"), ("FLIP", "UP DOWN"), ("RESTART", "R"), ("PAUSE", "ESC"),
                 ("MENUS", "ARROWS ENTER")]
CONTROLS_PAD = [("STEER", "L-STICK"), ("TUCK", "STICK DOWN"), ("OLLIE", "A"), ("GRABS", "X B Y X+B"),
                ("SPIN", "STICK L/R"), ("FLIP", "STICK U/D"), ("RESTART", "START"), ("PAUSE", "SELECT"),
                ("MENUS", "D-PAD A B")]

PAUSE_TOP, PAUSE_STEP = 54, 13   # the pause menu's first row and row pitch (grid pixels)

# The results' tally (resStep counts the lines shown, 0..7)
TALLY = [("TRICKS", "resTricks"), ("GRINDS", "resGrinds"), ("COMBO BONUS", "resComboBonus"),
         ("LANDINGS", "resLandings"), ("TIME BONUS", "resTimeBonus")]
GRADES = [("C", GREY_CHROME, "FF404858"), ("B", CYAN_CHROME, "FF0868A0"), ("A", PINK_CHROME, "FFA00850"),
          ("S", GOLD_CHROME, "FFA06000")]


# ---------------------------------------------------------------------------
# Drawing helpers
# ---------------------------------------------------------------------------

class Ctx:
    """The document, its view models and the shared converters."""

    def __init__(self, preview=False):
        self.doc = Doc(CLIENT)
        self.preview = preview
        self.fonts = {}
        self.last_sem = None

    def font(self, key):
        if key not in self.fonts:
            fid = self.doc.ids()
            if key == PIX:
                self.fonts[key] = fid
                self.doc.root(El("FontAsset", {"file": "fonts/PressStart2P-Regular.ttf", "name": "Press Start 2P",
                                               "id": fid}))
            else:
                self.fonts[key] = fid
                self.doc.root(El("FontAsset", {"file": "fonts/Saira-Italic-VF.ttf", "name": "Saira Italic",
                                               "id": fid}))
        return self.fonts[key]


def gradient(stops, h, y0=0.0):
    g = El("LinearGradient", {"startX": 0, "startY": y0, "endX": 0, "endY": y0 + h, "name": "Chrome"})
    for pos, col in stops:
        g.add(El("GradientStop", {"colorValue": col, "position": pos, "name": "Stop"}))
    return g


def tstyle(c, font, size, color, outline=None, ow=2.0, grad=None, grad_y0=0.0, sid=None, color_id=None,
           outline_id=None, name="Style"):
    sid = sid or c.doc.ids()
    st = El("TextStylePaint", {"fontSize": size, "lineHeight": size if font == PIX else None,
                               "fontAssetId": c.font(font), "name": name, "id": sid})
    if outline:
        st.add(El("Stroke", {"thickness": ow, "cap": "square", "join": "miter", "name": "Outline"},
                  El("SolidColor", {"colorValue": outline, "name": "Color", "id": outline_id})))
    if grad:
        st.add(El("Fill", {"name": "Fill"}, gradient(grad, size * 0.74, grad_y0)))
    else:
        st.add(El("Fill", {"name": "Fill"}, El("SolidColor", {"colorValue": color, "name": "Color", "id": color_id})))
    if font == DISP:
        st.add(El("TextStyleAxis", {"tag": TAG_WGHT, "axisValue": 900, "name": "Weight"}),
               El("TextStyleAxis", {"tag": TAG_WDTH, "axisValue": 125, "name": "Width"}))
    return st


def bind(path, key, conv=None):
    return El("DataBindContext", {"sourcePathIds": path, "propertyKey": key, "converterId": conv})


def text(c, name, value, font, size, x=0, y=0, ax=0.0, ay=0.0, color=WHITE, outline=BLACK, ow=None,
         shadow=1, shadow_color=BLACK, bind_path=None, conv=None, runs=None, width=None, grad=None,
         color_id=None, nid=None, opacity=None, sem=None):
    """A line of text as a Node at (x, y): the glyphs in `color` (or a chrome
    `grad`) with an `outline`, over a hard `shadow` (pixels down and right) in
    `shadow_color`. (ax, ay) is the anchor in the text's own box. `runs`:
    more (value, font, size, color, bind, conv) after the first. `width`
    makes the box fixed (the text shrinks to fit it). Returns the Node."""
    nid = nid or c.doc.ids()
    if ow is None:
        ow = 2.0 if font == PIX or size < 20 else 3.0
    node = El("Node", {"x": x, "y": y, "opacity": opacity, "name": name, "id": nid})

    def one(label, col, out, grad_, dx, dy, cid):
        a = {"x": dx or None, "y": dy or None, "originX": ax, "originY": ay}
        if width:
            a.update({"width": width, "height": size * 1.4, "sizingValue": "fixed", "overflowValue": "fitFontSize",
                      "alignValue": "left" if ax == 0 else ("center" if ax == 0.5 else "right"),
                      "verticalAlignValue": "middle"})
        else:
            a.update({"sizingValue": "autoWidth", "alignValue": "left" if ax == 0 else ("center" if ax == 0.5 else
                                                                                         "right")})
        a["name"] = label
        t = El("Text", a)
        sid = c.doc.ids()
        t.add(tstyle(c, font, size, col, out, ow, grad_, size * 0.40, sid, cid))
        styles = []
        for r in runs or []:
            rsid = c.doc.ids()
            rv, rf, rs, rc = r[0], r[1], r[2], r[3]
            rcol = rc if col != shadow_color else shadow_color
            styles.append((rsid, r))
            t.add(tstyle(c, rf, rs, rcol, out, 2.0 if rf == PIX or rs < 20 else 3.0, None, 0, rsid))
        run = El("TextValueRun", {"styleId": sid, "text": value, "name": "Run"})
        if bind_path:
            run.add(bind(bind_path, 268, conv))
        t.add(run)
        for i, (rsid, r) in enumerate(styles):
            rr = El("TextValueRun", {"styleId": rsid, "text": r[0], "name": "Run %d" % (i + 2)})
            if len(r) > 4 and r[4]:
                rr.add(bind(r[4], 268, r[5] if len(r) > 5 else None))
            t.add(rr)
        return t

    main = one(name + " Text", color, outline, grad, 0, 0, color_id)
    c.last_sem = sem
    if sem:
        main.add(sem)
        if opacity == 0:
            # starts invisible: out of the semantics until an animation shows it
            sem.set("isHidden", True)
            c.doc.link_sem(nid, sem)
    node.add(main)
    if shadow:
        node.add(one(name + " Shadow", shadow_color, shadow_color, None, shadow, shadow, None))
    return node


def shape(c, name, geom, fill=None, stroke=None, sw=1, x=0, y=0, fill_id=None, stroke_id=None, sid=None,
          opacity=None):
    s = El("Shape", {"x": x or None, "y": y or None, "opacity": opacity, "name": name, "id": sid or c.doc.ids()}, geom)
    if stroke:
        s.add(El("Stroke", {"thickness": sw, "cap": "square", "join": "miter", "name": "Stroke"},
                 El("SolidColor", {"colorValue": stroke, "name": "Color", "id": stroke_id})))
    if fill:
        s.add(El("Fill", {"name": "Fill"}, El("SolidColor", {"colorValue": fill, "name": "Color", "id": fill_id})))
    return s


def rect(w, h, ox=0.0, oy=0.0, rid=None, bind_w=None):
    r = El("Rectangle", {"width": w, "height": h, "originX": ox, "originY": oy, "name": "Path", "id": rid})
    if bind_w:
        r.add(bind(*bind_w))
    return r


def poly(pts, closed=True):
    p = El("PointsPath", {"isClosed": closed, "name": "Path"})
    for px, py in pts:
        p.add(El("StraightVertex", {"x": px, "y": py}))
    return p


def slant(x, y, w, h, k):
    """A parallelogram leaning right by `k` pixels over its height."""
    return poly([(x + k, y), (x + w + k, y), (x + w, y + h), (x, y + h)])


def node(c, name, *kids, x=None, y=None, nid=None, opacity=None):
    return El("Node", {"x": x, "y": y, "opacity": opacity, "name": name, "id": nid or c.doc.ids()}, *kids)


def nested(c, board, name, nid=None, x=None, y=None, quantize=None):
    return El("NestedArtboard", {"artboardId": board.id, "x": x, "y": y, "quantize": quantize, "name": name,
                                 "id": nid or c.doc.ids()},
              El("NestedStateMachine", {"animationId": board.sm.id, "name": board.sm.name}))


def slam_tracks(nid, frames_in=15, big=1.6, shake=1, motion=True):
    """The era's slam: scale 160 % -> 92 % -> 100 % over 0.25 s, then a
    1-pixel shake (docs/LOOK.md, section 8)."""
    if not motion:
        return [(nid, "opacity", "double", [(0, 0, "linear"), (9, 1, None)]),
                (nid, "scaleX", "double", [(0, 1, None)]), (nid, "scaleY", "double", [(0, 1, None)])]
    mid = int(frames_in * 0.6)
    tr = [(nid, "opacity", "double", [(0, 1, None)]),
          (nid, "scaleX", "double", [(0, big, "out"), (mid, 0.92, "inOut"), (frames_in, 1, None)]),
          (nid, "scaleY", "double", [(0, big, "out"), (mid, 0.92, "inOut"), (frames_in, 1, None)])]
    return tr


def shake_track(nid, x0, start, amp=1, steps=4):
    keys = [(0, x0, None)]
    f = start
    for i in range(steps):
        keys.append((f, x0 + (amp if i % 2 == 0 else -amp), None))
        f += 2
    keys.append((f, x0, None))
    return (nid, "x", "double", keys)


# ---------------------------------------------------------------------------
# View models
# ---------------------------------------------------------------------------

class Models:
    def __init__(self, c):
        doc = c.doc
        gd = doc.view_model("GameData", comment="GameData: the Scene3D's `data`, one property per pin of tools/pins.py:\n"
                                                "the world writes the `out` rows, the Rive side the `in` rows.")
        for name, kind, _, meaning in PINS:
            gd.prop(name, "number" if kind == "number" else "boolean", DEFAULTS.get(name, 0 if kind == "number"
                                                                                     else False))
        gd.instance("Default")
        self.gd = gd

        u = doc.view_model("Ui", comment="Ui: the Rive side's own data: the strings ui/trick_text.as composes from\n"
                                         "the pins, the grid's place ui/fit.as works out, the menus' selections.")
        for k, v in (("scale", 3), ("gx", 0), ("gy", 0), ("balX", 160), ("balY", 150), ("pauseSel", 0),
                     ("ini0", 1), ("ini1", 1), ("ini2", 1), ("iniCursor", 0)):
            u.prop(k, "number", v)
        u.prop("iniDone", "boolean", False)
        u.prop("captions", "boolean", True, comment="the announcer's captions shown (the pause menu's setting)")
        u.prop("highContrast", "boolean", False, comment="plates behind the HUD's readouts (the pause menu's setting)")
        for k, v in (("trickText", "BACKSIDE 720 INDY"), ("trickPts", "+1,050"), ("praiseText", "SICK!"),
                     ("comboText", "2,450 x 3"), ("captionText", ""), ("totalText", "0"), ("bestText", "0"),
                     ("airText", "0.0S"), ("schemeName", "HOT PINK"), ("iniText0", "A"), ("iniText1", "A"),
                     ("iniText2", "A")):
            u.prop(k, "string", v)
        for i in range(1, 11):
            u.prop("hs%dName" % i, "string", "---")
            u.prop("hs%dPts" % i, "string", "0")
            u.prop("hs%dGrade" % i, "string", "C")
            u.prop("hs%dLine" % i, "string", "L")
        u.prop("controls", "boolean", False, comment="the pause menu shows the controls card")
        for k in ("pauseGo", "pauseLeft", "pauseRight", "pauseBack"):
            u.prop(k, "trigger")
        u.instance("Default")
        self.u = u

        g = doc.view_model("Game", comment="Game: the Scene3D component's properties (hedra_engine/scene3d.as) and\n"
                                           "`data` (GameData, the world's), `ui` (Ui, the Rive side's): Main's.")
        g.prop("scene", "string", "world/run.rscn")
        g.prop("source", "string", "auto")
        g.prop("unbuiltLabel", "boolean", False)
        g.prop("playing", "boolean", True)
        g.prop("speed", "number", 1)
        g.prop("status", "string", "")
        g.prop("data", "viewModel", gd.default(), ref=gd)
        g.prop("ui", "viewModel", u.default(), ref=u)
        g.instance("Default")
        self.g = g

    def d(self, name):
        return self.g.path("data", name)

    def u_(self, name):
        return self.g.path("ui", name)


class Conv:
    """The converters the binds share."""

    def __init__(self, c):
        doc = c.doc
        self.whole = doc.conv_whole()
        self.d2 = doc.conv_decimals(2)
        self.percent = doc.group("Percent", doc.conv_range(0, 1, 0, 100), self.whole)
        self.notc = doc.conv_not()
        self.plus1 = doc.conv_plus(1)
        self.score = doc.group("Score six digits", self.whole, doc.conv_pad(6))
        mins = doc.formula("Minutes", f_fn("floor"), f_in(), f_op("/"), f_val(60), f_close())
        secs = doc.formula("Seconds of the minute", f_fn("floor"), f_in(), f_close(), f_op("%"), f_val(60))
        hund = doc.formula("Hundredths", f_fn("floor"), f_in(), f_op("*"), f_val(100), f_close(), f_op("%"),
                           f_val(100))
        pad2 = doc.conv_pad(2)
        self.clock_m = doc.group("Clock minutes", mins, self.whole)
        self.clock_s = doc.group("Clock seconds", secs, self.whole, pad2)
        self.clock_h = doc.group("Clock hundredths", hund, self.whole, pad2)
        self.next3 = doc.conv_cycle(1, 3)
        self.prev3 = doc.conv_cycle(-1, 3)
        n = len(PAUSE_ITEMS)
        self.pause_next = doc.conv_cycle(1, n)
        self.pause_prev = doc.conv_cycle(-1, n)
        self.vol_up = doc.formula("Volume up", f_fn("min"), f_val(1), f_sep(), f_fn("round"), f_in(), f_op("*"),
                                  f_val(10), f_op("+"), f_val(1), f_close(), f_op("/"), f_val(10), f_close())
        self.vol_down = doc.formula("Volume down", f_fn("max"), f_val(0), f_sep(), f_fn("round"), f_in(), f_op("*"),
                                    f_val(10), f_op("-"), f_val(1), f_close(), f_op("/"), f_val(10), f_close())
        self.vol_bars = doc.formula("Volume bars", f_fn("round"), f_in(), f_op("*"), f_val(10), f_close(), f_op("*"),
                                    f_val(5))
        self.progress = doc.conv_range(0, 1, 0, 200)
        self.balance = doc.conv_range(-1, 1, -22, 22)
        self.pop = doc.conv_range(0, 1, 0, 46)
        self.pause_y = doc.formula("Pause row y", f_in(), f_op("*"), f_val(PAUSE_STEP))
        self.caret_x = doc.formula("Caret x", f_in(), f_op("*"), f_val(48))
        self.rank_y = doc.formula("Rank row y", f_in(), f_op("*"), f_val(10))


# ---------------------------------------------------------------------------
# The HUD (docs/RIVE.md, section 5)
# ---------------------------------------------------------------------------

def hud_board(c, m, cv):
    doc = c.doc
    b = doc.board("HudOverlay", GRID_W, GRID_H, component=True, clip=False, machine="Hud",
                  comment="HudOverlay: the run's HUD on the 320 x 240 grid (docs/RIVE.md, section 5): score, combo\n"
                          "multiplier, timer, the trick banner, the praise word, the combo's sum, the balance\n"
                          "meter, the countdown and the grade targets, the progress strip, the perfect flash.\n"
                          "Nested in Main with no data of its own: it shares Game's.")
    d, u = m.d, m.u_
    rm = d("reducedMotion")
    sm = b.sm

    # --- the perfect flash: a border at 30 % for 120 ms, and PERFECT! above the banner
    flash_id = doc.ids()
    flash = node(c, "Perfect Flash", nid=flash_id, opacity=0)
    for nm, (x, y, w, h) in (("Top", (0, 0, 320, 6)), ("Bottom", (0, 234, 320, 6)), ("Left", (0, 6, 6, 228)),
                             ("Right", (314, 6, 6, 228))):
        flash.add(shape(c, "Flash " + nm, rect(w, h), fill=WHITE, x=x, y=y))
    perfect_id = doc.ids()
    perfect = text(c, "Perfect", "PERFECT!", DISP, 12, 160, 62, 0.5, 0.5, color=CYAN, outline=BLACK, nid=perfect_id,
                   opacity=0, sem=semantics("text", "Perfect landing", isLiveRegion=True))

    # --- the countdown: big chrome digits; the grade targets under it
    cd_ids = {}
    cd_nodes = []
    for key, label, grad in (("3", "3", CHROME), ("2", "2", CHROME), ("1", "1", CHROME), ("go", "GO!", GREEN_CHROME),
                             ("ready", "READY", CHROME)):
        nid = doc.ids()
        size = 80 if key not in ("ready", "go") else (64 if key == "go" else 44)
        cd_ids[key] = nid
        t = text(c, "Count " + label, label, DISP, size, 160, 92, 0.5, 0.5, grad=grad,
                 outline=PINK if key != "go" else BLACK, ow=4, shadow=3, nid=nid, opacity=0,
                 sem=semantics("text", label.capitalize() if key != "go" else "Go", isLiveRegion=True))
        cd_nodes.append(t)
    targets_id = doc.ids()
    targets = node(c, "Targets", nid=targets_id, opacity=0)
    targets.add(text(c, "Targets Label", "GRADE TARGETS", PIX, 8, 160, 155, 0.5, 0, color=CYAN),
                text(c, "Targets Line", "S 50,000  A 35,000  B 20,000", PIX, 8, 160, 166, 0.5, 0, color=WHITE,
                     runs=None, sem=semantics("text", "Grade targets: S 50,000, A 35,000, B 20,000", isHidden=True)),
                shape(c, "Targets Plate", slant(36, 0, 244, 24, 6), fill="C80C1448", stroke=CYAN, y=152))
    doc.link_sem(targets_id, c.last_sem)

    # --- the trick banner (y 70 to 100) and the points
    banner_id, banner_pos = doc.ids(), doc.ids()
    banner = node(c, "Banner", nid=banner_pos, x=160, y=84, opacity=0)
    banner_inner = node(c, "Banner Slam", nid=banner_id)
    banner_inner.add(text(c, "Trick Name", "BACKSIDE 720 INDY", DISP, 16, 0, 0, 0.5, 0.5, color=WHITE, outline=PINK,
                          shadow=2, bind_path=u("trickText"), width=304,
                          sem=semantics("text", bind_label=u("trickText"), isLiveRegion=True, isHidden=True)))
    doc.link_sem(banner_pos, c.last_sem)
    pts_id = doc.ids()
    banner_inner.add(text(c, "Trick Points", "+1,050", PIX, 8, 0, 12, 0.5, 0, color=GOLD, nid=pts_id,
                          bind_path=u("trickPts")))
    banner.add(banner_inner)

    # --- the praise word (y 104 to 124) and the combo's running sum (y 128)
    praise_pos, praise_id = doc.ids(), doc.ids()
    praise = node(c, "Praise", nid=praise_pos, x=160, y=116, opacity=0)
    praise.add(text(c, "Praise Word", "SICK!", DISP, 22, 0, 0, 0.5, 0.5, color=GREEN, outline=ORANGE, ow=3, shadow=2,
                    nid=praise_id, bind_path=u("praiseText"),
                    sem=semantics("text", bind_label=u("praiseText"), isLiveRegion=True, isHidden=True)))
    doc.link_sem(praise_pos, c.last_sem)
    combo_sum_id = doc.ids()
    combo_sum = text(c, "Combo Sum", "2,450 x 3", PIX, 8, 160, 132, 0.5, 0, color=WHITE, nid=combo_sum_id, opacity=0,
                     bind_path=u("comboText"), sem=semantics("text", bind_label=u("comboText")))

    # --- the balance meter under the rider (48 x 6, its needle at `balance`, red past 0.7)
    bal_id, needle_c = doc.ids(), doc.ids()
    bal = El("Node", {"opacity": 0, "name": "Balance", "id": bal_id},
             bind(u("balX"), 13), bind(u("balY"), 14))
    needle =El("Shape", {"name": "Needle", "id": doc.ids()}, bind(d("balance"), 13, cv.balance),
                rect(2, 10, 0.5, 0.5),
                El("Stroke", {"thickness": 1, "name": "Stroke"}, El("SolidColor", {"colorValue": BLACK, "name": "C"})),
                El("Fill", {"name": "Fill"}, El("SolidColor", {"colorValue": WHITE, "name": "C", "id": needle_c})))
    bal.add(needle,
            shape(c, "Safe", rect(30, 4, 0.5, 0.5), fill=GREEN),
            shape(c, "Danger Left", rect(8, 4, 0, 0.5), fill=RED, x=-24),
            shape(c, "Danger Right", rect(8, 4, 1, 0.5), fill=RED, x=24),
            shape(c, "Bar", rect(48, 6, 0.5, 0.5), fill=BLACK, stroke=WHITE, sw=1),
            text(c, "Balance Label", "BALANCE", PIX, 8, 0, 6, 0.5, 0, color=ORANGE,
                 sem=semantics("text", "Balance", value=d("balance"), value_conv=cv.d2, isHidden=True)))
    doc.link_sem(bal_id, c.last_sem)

    # --- the ollie's pop meter under the rider (where the balance meter sits:
    # never at once, a grind shows the balance), filling with the crouch's
    # charge, acid green when full
    pop_id, pop_fill_c = doc.ids(), doc.ids()
    pop = El("Node", {"opacity": 0, "name": "Pop", "id": pop_id},
             bind(u("balX"), 13), bind(u("balY"), 14))
    # (above the rider's head: the balance meter's anchor less 44 grid pixels;
    # the fill first, drawn over the bar)
    pop.add(El("Shape", {"x": -23, "y": -44, "name": "Pop Fill", "id": doc.ids()},
               rect(0, 4, 0, 0.5, bind_w=(d("ollieCharge"), 20, cv.pop)),
               El("Fill", {"name": "Fill"}, El("SolidColor", {"colorValue": ORANGE, "name": "C", "id": pop_fill_c}))),
            shape(c, "Pop Bar", rect(48, 6, 0.5, 0.5), fill=BLACK, stroke=WHITE, sw=1, y=-44),
            text(c, "Pop Label", "POP", PIX, 8, 0, -58, 0.5, 0, color=ORANGE,
                 sem=semantics("text", "Ollie charge", value=d("ollieCharge"), value_conv=cv.d2, isHidden=True)))
    doc.link_sem(pop_id, c.last_sem)

    # --- the top row: score (8, 8), timer (160, 8), combo multiplier (312, 8)
    score = node(c, "Score")
    score.add(text(c, "Score Label", "SCORE", PIX, 8, 8, 8, color=CYAN),
              text(c, "Score Value", "000000", PIX, 16, 8, 18, bind_path=d("score"), conv=cv.score,
                   sem=semantics("text", "Score", value=d("score"), value_conv=cv.whole)))
    timer = node(c, "Timer")
    timer.add(text(c, "Time Label", "TIME", PIX, 8, 160, 8, 0.5, 0, color=CYAN),
              text(c, "Time Value", "0", PIX, 16, 160, 18, 0.5, 0, bind_path=d("time"), conv=cv.clock_m,
                   runs=[(":", PIX, 16, WHITE), ("00", PIX, 16, WHITE, d("time"), cv.clock_s),
                         (".", PIX, 8, WHITE), ("00", PIX, 8, WHITE, d("time"), cv.clock_h)],
                   sem=semantics("text", "Time, in seconds", value=d("time"), value_conv=cv.d2)))
    mult_on, mult_off, mult_bump = doc.ids(), doc.ids(), doc.ids()
    mult = node(c, "Multiplier")
    mult.add(text(c, "Combo Label", "COMBO", PIX, 8, 312, 8, 1.0, 0, color=CYAN))
    on = node(c, "Mult Active", nid=mult_on, opacity=0, x=312, y=18)
    on_inner = node(c, "Mult Bump", nid=mult_bump)
    on_inner.add(text(c, "Mult Value", "x", DISP, 16, 0, 12, 1.0, 0.5, color=PINK, outline=WHITE, ow=2, shadow=2,
                      runs=[("0", DISP, 24, PINK, d("comboMult"), cv.whole)],
                      sem=semantics("text", "Combo multiplier", value=d("comboMult"), value_conv=cv.whole,
                                    isHidden=True)))
    doc.link_sem(mult_on, c.last_sem)
    on.add(on_inner)
    off = text(c, "Mult Idle", "x1", DISP, 16, 312, 26, 1.0, 0.5, color=DIM, outline=BLACK, nid=mult_off)
    mult.add(on, off)

    # --- the progress strip (y 228, 200 wide): seven sections, a dot for the rider
    prog = node(c, "Progress", x=60, y=226)
    dot = El("Shape", {"name": "Rider Dot", "id": doc.ids()}, bind(d("progress"), 13, cv.progress),
             poly([(0, -3), (4, 2), (0, 7), (-4, 2)]),
             El("Stroke", {"thickness": 1, "name": "Stroke"}, El("SolidColor", {"colorValue": BLACK, "name": "C"})),
             El("Fill", {"name": "Fill"}, El("SolidColor", {"colorValue": WHITE, "name": "C"})))
    prog.add(dot)
    for i in range(1, 7):
        prog.add(shape(c, "Tick %d" % i, rect(1, 4), fill=BLACK, x=round(200 * i / 7.0)))
    prog.add(El("Shape", {"name": "Done", "id": doc.ids()},
                rect(0, 4, rid=None, bind_w=(d("progress"), 20, cv.progress)),
                El("Fill", {"name": "Fill"}, El("SolidColor", {"colorValue": PINK, "name": "C"}))))
    prog.add(shape(c, "Track", rect(200, 4), fill=NAVY, stroke=BLACK, sw=2),
             semantics("text", "Course progress, percent", value=d("progress"), value_conv=cv.percent))

    # high contrast (docs/SPEC.md, section 12): dark plates behind the readouts and the banner
    plates_id = doc.ids()
    plates = node(c, "Contrast Plates", nid=plates_id, opacity=0)
    for nm, (x, y, w, h) in (("Score", (4, 5, 104, 32)), ("Time", (112, 5, 100, 32)), ("Combo", (252, 5, 64, 36)),
                             ("Banner", (6, 72, 308, 34)), ("Praise", (60, 104, 200, 38)), ("Strip", (56, 222, 208, 12))):
        plates.add(shape(c, "Plate " + nm, slant(x, y, w, h, 4), fill="D0000000"))
    b.add(flash, perfect, *cd_nodes, targets, banner, praise, combo_sum, bal, pop, score, timer, mult, prog, plates)

    # ---- machine: the layers of docs/RIVE.md, section 3 ("Hud")
    motion_on = when(rm, "boolean", value=False)
    motion_off = when(rm, "boolean", value=True)

    # Banner: Idle -> Live (growing, small) -> Slam on bankSeq -> Hold 1.2 s -> Out (slides left)
    lay = sm.layer("Banner")
    idle = lay.state("Idle", b.pose("Banner Idle", [(banner_pos, "opacity", "double", 0), (banner_pos, "x", "double", 160),
                                                    (banner_id, "scaleX", "double", 1), (banner_id, "scaleY", "double", 1),
                                                    (pts_id, "opacity", "double", 0)]))
    live = lay.state("Live", b.pose("Banner Live", [(banner_pos, "opacity", "double", 0.85),
                                                    (banner_pos, "x", "double", 160),
                                                    (banner_id, "scaleX", "double", 0.75),
                                                    (banner_id, "scaleY", "double", 0.75),
                                                    (pts_id, "opacity", "double", 0)]))
    slam_f = 15
    slam = lay.state("Slam", b.timeline("Banner Slam", slam_f + 9, [
        (banner_pos, "opacity", "double", [(0, 1, None)]),
        (pts_id, "opacity", "double", [(0, 0, None), (slam_f, 1, None)]),
        shake_track(banner_pos, 160, slam_f, 1),
    ] + slam_tracks(banner_id, slam_f)[1:]))
    slam_still = lay.state("Slam Still", b.timeline("Banner Fade", 9, [
        (banner_pos, "x", "double", [(0, 160, None)]), (pts_id, "opacity", "double", [(0, 1, None)]),
        (banner_id, "scaleX", "double", [(0, 1, None)]), (banner_id, "scaleY", "double", [(0, 1, None)]),
        (banner_pos, "opacity", "double", [(0, 0, "linear"), (9, 1, None)])]))
    hold = lay.state("Hold", b.timeline("Banner Hold", 72, [
        (banner_pos, "opacity", "double", [(0, 1, None)]), (pts_id, "opacity", "double", [(0, 1, None)]),
        (banner_pos, "x", "double", [(0, 160, None)])]))
    out = lay.state("Out", b.timeline("Banner Out", 9, [
        (banner_pos, "x", "double", [(0, 160, "in"), (9, -200, None)]),
        (banner_pos, "opacity", "double", [(0, 1, None), (9, 0, None)])]))
    out_still = lay.state("Out Still", b.timeline("Banner Out Fade", 9, [
        (banner_pos, "x", "double", [(0, 160, None)]),
        (banner_pos, "opacity", "double", [(0, 1, "linear"), (9, 0, None)])]))
    bank = changed(doc, d("bankSeq"))
    is_live = when(d("trickLive"), "boolean", value=True)
    not_live = when(d("trickLive"), "boolean", value=False)
    for s in (idle, live, hold, out, out_still):
        s.to(slam, bank, motion_on)
        s.to(slam_still, bank, motion_off)
    idle.to(live, is_live)
    live.to(idle, not_live)
    slam.to(hold, exit_at=100)
    slam_still.to(hold, exit_at=100)
    hold.to(live, is_live)
    hold.to(out, motion_on, exit_at=100)
    hold.to(out_still, motion_off, exit_at=100)
    out.to(idle, exit_at=100)
    out_still.to(idle, exit_at=100)

    # Praise: on a bank (and a crash or a bail) with praise > 0, the word slams
    # 0.1 s after the banner and holds 1.0 s
    lay = sm.layer("Praise")
    p_idle = lay.state("Idle", b.pose("Praise Idle", [(praise_pos, "opacity", "double", 0)]))
    pf = 6 + 15 + 60 + 9
    p_slam = lay.state("Slam", b.timeline("Praise Slam", pf, [
        (praise_pos, "opacity", "double", [(0, 0, None), (6, 1, None), (pf - 9, 1, "linear"), (pf, 0, None)]),
        (praise_id, "scaleX", "double", [(0, 1.8, None), (6, 1.8, "out"), (6 + 9, 0.92, "inOut"), (6 + 15, 1, None)]),
        (praise_id, "scaleY", "double", [(0, 1.8, None), (6, 1.8, "out"), (6 + 9, 0.92, "inOut"), (6 + 15, 1, None)]),
        shake_track(praise_pos, 160, 6 + 15, 1)]))
    p_fade = lay.state("Fade", b.timeline("Praise Fade", pf, [
        (praise_id, "scaleX", "double", [(0, 1, None)]), (praise_id, "scaleY", "double", [(0, 1, None)]),
        (praise_pos, "opacity", "double", [(0, 0, None), (6, 0, "linear"), (15, 1, None), (pf - 9, 1, "linear"),
                                           (pf, 0, None)])]))
    has = when(d("praise"), "number", "greaterThan", 0)
    for seq in ("bankSeq", "crashSeq", "bailSeq"):
        for s in (p_idle,):
            s.to(p_slam, changed(doc, d(seq)), has, motion_on)
            s.to(p_fade, changed(doc, d(seq)), has, motion_off)
    p_slam.to(p_idle, exit_at=100)
    p_fade.to(p_idle, exit_at=100)

    # Perfect: perfectSeq -> the border at 30 % for 120 ms (none with reduced
    # motion) and PERFECT! for 1.2 s
    lay = sm.layer("Perfect")
    f_idle = lay.state("Idle", b.pose("Perfect Idle", [(flash_id, "opacity", "double", 0),
                                                      (perfect_id, "opacity", "double", 0)]))
    f_on = lay.state("Flash", b.timeline("Perfect Flash", 72, [
        (flash_id, "opacity", "double", [(0, 0.3, None), (7, 0, None)]),
        (perfect_id, "opacity", "double", [(0, 1, None), (63, 1, "linear"), (72, 0, None)]),
        (perfect_id, "scaleX", "double", [(0, 1.4, "out"), (9, 1, None)]),
        (perfect_id, "scaleY", "double", [(0, 1.4, "out"), (9, 1, None)])]))
    f_still = lay.state("Word Only", b.timeline("Perfect Word", 72, [
        (flash_id, "opacity", "double", [(0, 0, None)]),
        (perfect_id, "opacity", "double", [(0, 0, "linear"), (6, 1, None), (63, 1, "linear"), (72, 0, None)])]))
    pseq = changed(doc, d("perfectSeq"))
    f_idle.to(f_on, pseq, motion_on)
    f_idle.to(f_still, pseq, motion_off)
    f_on.to(f_idle, exit_at=100)
    f_still.to(f_idle, exit_at=100)

    # Combo: comboActive -> the sum under the praise, the multiplier big in pink
    lay = sm.layer("Combo")
    c_idle = lay.state("Idle", b.pose("Combo Idle", [(combo_sum_id, "opacity", "double", 0),
                                                    (mult_on, "opacity", "double", 0),
                                                    (mult_off, "opacity", "double", 1)]))
    c_on = lay.state("Active", b.pose("Combo Active", [(combo_sum_id, "opacity", "double", 1),
                                                      (mult_on, "opacity", "double", 1),
                                                      (mult_off, "opacity", "double", 0)]))
    lay.any.to(c_on, when(d("comboActive"), "boolean", value=True))
    lay.any.to(c_idle, when(d("comboActive"), "boolean", value=False))
    lay = sm.layer("Combo Bump")
    cb_idle = lay.state("Still", b.pose("Bump Still", [(mult_bump, "scaleX", "double", 1),
                                                      (mult_bump, "scaleY", "double", 1)]))
    cb_on = lay.state("Bump", b.timeline("Bump", 12, [
        (mult_bump, "scaleX", "double", [(0, 1.5, "out"), (12, 1, None)]),
        (mult_bump, "scaleY", "double", [(0, 1.5, "out"), (12, 1, None)])]))
    cb_idle.to(cb_on, changed(doc, d("trickSeq")), motion_on)
    cb_on.to(cb_idle, exit_at=100)

    # Balance: shown while grinding; the needle red past 0.7
    lay = sm.layer("Balance")
    b_off = lay.state("Hidden", b.pose("Balance Hidden", [(bal_id, "opacity", "double", 0)]))
    b_on = lay.state("Shown", b.pose("Balance Shown", [(bal_id, "opacity", "double", 1)]))
    lay.any.to(b_on, when(d("grinding"), "boolean", value=True))
    lay.any.to(b_off, when(d("grinding"), "boolean", value=False))
    lay = sm.layer("Needle")
    n_ok = lay.state("Safe", b.pose("Needle Safe", [(needle_c, "colorValue", "color", WHITE)]))
    n_bad = lay.state("Danger", b.pose("Needle Danger", [(needle_c, "colorValue", "color", RED)]))
    n_ok.to(n_bad, when(d("balance"), "number", "greaterThan", 0.7))
    n_ok.to(n_bad, when(d("balance"), "number", "lessThan", -0.7))
    n_bad.to(n_ok, when(d("balance"), "number", "lessThanOrEqual", 0.7),
             when(d("balance"), "number", "greaterThanOrEqual", -0.7))

    # Pop: shown while the ollie's crouch charges (and no grind); full in acid green
    lay = sm.layer("Pop")
    p_off = lay.state("Hidden", b.pose("Pop Hidden", [(pop_id, "opacity", "double", 0)]))
    p_on = lay.state("Shown", b.pose("Pop Shown", [(pop_id, "opacity", "double", 1)]))
    p_off.to(p_on, when(d("ollieCharge"), "number", "greaterThan", 0.02), when(d("grinding"), "boolean", value=False))
    p_on.to(p_off, when(d("ollieCharge"), "number", "lessThanOrEqual", 0.02))
    p_on.to(p_off, when(d("grinding"), "boolean", value=True))
    lay = sm.layer("Pop Fill")
    pf_part = lay.state("Loading", b.pose("Pop Loading", [(pop_fill_c, "colorValue", "color", ORANGE)]))
    pf_full = lay.state("Full", b.pose("Pop Full", [(pop_fill_c, "colorValue", "color", GREEN)]))
    pf_part.to(pf_full, when(d("ollieCharge"), "number", "greaterThanOrEqual", 0.99))
    pf_full.to(pf_part, when(d("ollieCharge"), "number", "lessThan", 0.99))

    # Countdown: 3, 2, 1 slam on their beat; GO! in acid green, held then out; READY for a quick start
    lay = sm.layer("Countdown")
    all_off = [(nid, "opacity", "double", 0) for nid in cd_ids.values()]
    c_off = lay.state("Off", b.pose("Count Off", all_off))
    states = {}
    for key, value in (("3", 3), ("2", 2), ("1", 1), ("ready", 10)):
        nid = cd_ids[key]
        others = [(o, "opacity", "double", [(0, 0, None)]) for k2, o in cd_ids.items() if k2 != key]
        st = lay.state("Count " + key, b.timeline("Count " + key, 15, others + slam_tracks(nid, 12, 2.2)))
        st_still = lay.state("Count " + key + " Still", b.timeline("Count " + key + " Fade", 15, others + [
            (nid, "opacity", "double", [(0, 0, "linear"), (6, 1, None)]),
            (nid, "scaleX", "double", [(0, 1, None)]), (nid, "scaleY", "double", [(0, 1, None)])]))
        states[value] = (st, st_still)
    gid = cd_ids["go"]
    others = [(o, "opacity", "double", [(0, 0, None)]) for k2, o in cd_ids.items() if k2 != "go"]
    go = lay.state("Go", b.timeline("Count Go", 54, others + [
        (gid, "opacity", "double", [(0, 1, None), (42, 1, "linear"), (54, 0, None)]),
        (gid, "scaleX", "double", [(0, 2.4, "out"), (8, 0.92, "inOut"), (14, 1, None), (42, 1, "in"), (54, 1.6, None)]),
        (gid, "scaleY", "double", [(0, 2.4, "out"), (8, 0.92, "inOut"), (14, 1, None), (42, 1, "in"), (54, 1.6, None)])]))
    go_still = lay.state("Go Still", b.timeline("Count Go Fade", 54, others + [
        (gid, "scaleX", "double", [(0, 1, None)]), (gid, "scaleY", "double", [(0, 1, None)]),
        (gid, "opacity", "double", [(0, 0, "linear"), (6, 1, None), (42, 1, "linear"), (54, 0, None)])]))
    cdp = d("countdown")
    sources = [c_off] + [s for pair in states.values() for s in pair]
    for value, (st, st_still) in states.items():
        for src in sources:
            if src in (st, st_still):
                continue
            src.to(st, when(cdp, "number", value=value), motion_on)
            src.to(st_still, when(cdp, "number", value=value), motion_off)
    for st, st_still in states.values():
        for s in (st, st_still):
            s.to(go, when(cdp, "number", value=0), motion_on)
            s.to(go_still, when(cdp, "number", value=0), motion_off)
            s.to(c_off, when(cdp, "number", value=-1))
    go.to(c_off, exit_at=100)
    go_still.to(c_off, exit_at=100)

    # Contrast: the plates while Game/ui/highContrast
    lay = sm.layer("Contrast")
    hc_off = lay.state("Normal", b.pose("Contrast Normal", [(plates_id, "opacity", "double", 0)]))
    hc_on = lay.state("High", b.pose("Contrast High", [(plates_id, "opacity", "double", 1)]))
    lay.any.to(hc_on, when(u("highContrast"), "boolean", value=True))
    lay.any.to(hc_off, when(u("highContrast"), "boolean", value=False))

    # Targets: the grade targets during the count
    lay = sm.layer("Targets")
    t_off = lay.state("Hidden", b.pose("Targets Hidden", [(targets_id, "opacity", "double", 0)]))
    t_on = lay.state("Shown", b.pose("Targets Shown", [(targets_id, "opacity", "double", 1)]))
    lay.any.to(t_on, when(d("phase"), "number", value=1))
    lay.any.to(t_off, when(d("phase"), "number", "notEqual", 1))
    return b


# ---------------------------------------------------------------------------
# The title (docs/RIVE.md, section 6)
# ---------------------------------------------------------------------------

def logo(c, x, y, scale=1.0, nid=None):
    """AVALANCHE AIR: heavy extended italic chrome, a pink outline, a hard shadow."""
    n = node(c, "Logo", x=x, y=y, nid=nid)
    n.add(text(c, "Logo Air", "AIR", DISP, round(44 * scale), 58, 24, 0.5, 0, grad=CHROME, outline=PINK, ow=4,
               shadow=3, sem=None))
    n.add(text(c, "Logo Avalanche", "AVALANCHE", DISP, round(30 * scale), 0, 0, 0.5, 0, grad=CHROME, outline=PINK, ow=3,
               shadow=3, sem=semantics("text", "Avalanche Air", headingLevel=1)))
    return n


def title_board(c, m, cv):
    doc = c.doc
    b = doc.board("TitleOverlay", GRID_W, GRID_H, component=True, clip=False, machine="Title",
                  comment="TitleOverlay: PRESS START blinking, the scheme picker, the high score table (6 s every\n"
                          "20 s, in place of the logo), the credits line (docs/RIVE.md, section 6).")
    d, u = m.d, m.u_
    sm = b.sm
    logo_id, table_id, press_id, beat_id = doc.ids(), doc.ids(), doc.ids(), doc.ids()
    lg = logo(c, 148, 34, nid=logo_id)
    doc.link_sem(logo_id, c.last_sem)
    lg.add(text(c, "Strapline", "EXTREME TRICK ATTACK", PIX, 8, 12, 82, 0.5, 0, color=CYAN, shadow=1))

    # the table: rank, initials, score, grade, line
    table = node(c, "High Scores", nid=table_id, opacity=0)
    table.add(text(c, "Table Title", "HIGH SCORES", DISP, 16, 160, 18, 0.5, 0, color=WHITE, outline=PINK, shadow=2,
                   sem=semantics("text", "High scores", headingLevel=2, isHidden=True)))
    doc.link_sem(table_id, c.last_sem)
    rows = node(c, "Rows")
    for i in range(1, 11):
        y = 42 + (i - 1) * 11
        col = GOLD if i == 1 else (WHITE if i <= 3 else "FFC8D0E0")
        rows.add(text(c, "Rank %d" % i, "%d." % i if i < 10 else "10", PIX, 8, 72, y, 1.0, 0, color=PINK),
                 text(c, "Name %d" % i, "AVA", PIX, 8, 82, y, color=col, bind_path=u("hs%dName" % i)),
                 text(c, "Pts %d" % i, "45,000", PIX, 8, 216, y, 1.0, 0, color=col, bind_path=u("hs%dPts" % i)),
                 text(c, "Grade %d" % i, "S", PIX, 8, 228, y, color=GREEN, bind_path=u("hs%dGrade" % i)),
                 text(c, "Line %d" % i, "H", PIX, 8, 244, y, color=CYAN, bind_path=u("hs%dLine" % i)))
    table.add(rows, shape(c, "Table Plate", slant(56, 36, 208, 116, 8), fill="C80C1448", stroke=PINK, sw=2))

    press = node(c, "Press Start", nid=press_id, x=160, y=158)
    press_in = node(c, "Press Beat", nid=beat_id)
    press_in.add(text(c, "Press Start Text", "PRESS START", PIX, 16, 0, 0, 0.5, 0.5, color=WHITE, outline=BLACK,
                      shadow=2, sem=semantics("button", "Press start")))
    press.add(press_in)

    picker = node(c, "Scheme Picker", x=160, y=192)
    picker.add(text(c, "Scheme Left", "<", PIX, 8, -64, 0, 0.5, 0.5, color=PINK),
               text(c, "Scheme Name", "HOT PINK", PIX, 8, 0, 0, 0.5, 0.5, color=WHITE, bind_path=u("schemeName"),
                    sem=semantics("text", bind_label=u("schemeName"))),
               text(c, "Scheme Right", ">", PIX, 8, 64, 0, 0.5, 0.5, color=PINK),
               text(c, "Scheme Label", "BOARD", PIX, 8, 0, -12, 0.5, 0.5, color=CYAN))
    # the board's colours under its name (0 Hot Pink, 1 Acid, 2 Blaze)
    swatches = []
    sw_solo = doc.ids()
    for i, (a, bcol) in enumerate(((PINK, CYAN), (GREEN, BLACK), (ORANGE, GOLD))):
        sid = doc.ids()
        swatches.append(node(c, "Swatch %d" % i, shape(c, "Swatch A", slant(-28, 8, 28, 5, 3), fill=a, stroke=BLACK),
                             shape(c, "Swatch B", slant(0, 8, 28, 5, 3), fill=bcol, stroke=BLACK), nid=sid))
    picker.add(El("Solo", {"activeComponentId": swatches[0].get("id"), "name": "Swatches", "id": sw_solo}, *swatches))
    credits = text(c, "Credits", "(C) 1998 AVALANCHE AIR TEAM", PIX, 8, 160, 226, 0.5, 0, color=GREY)

    b.add(table, press, picker, credits, lg)

    lay = sm.layer("Scheme")
    for i, sw in enumerate(swatches):
        st = lay.state("Scheme %d" % i, b.pose("Scheme %d" % i, [(sw_solo, "activeComponentId", "id", sw.get("id"))]))
        lay.any.to(st, when(d("scheme"), "number", value=i))
    # PRESS START blinks; it pulses on the music's beat
    lay = sm.layer("Blink")
    blink = lay.state("Blink", b.timeline("Blink", 60, [
        (press_id, "opacity", "double", [(0, 1, None), (40, 0, None), (60, 0, None)])], loop="loop"))
    lay = sm.layer("Beat")
    bt_idle = lay.state("Still", b.pose("Beat Still", [(beat_id, "scaleX", "double", 1), (beat_id, "scaleY", "double", 1)]))
    bt_on = lay.state("Pulse", b.timeline("Beat Pulse", 10, [
        (beat_id, "scaleX", "double", [(0, 1.12, "out"), (10, 1, None)]),
        (beat_id, "scaleY", "double", [(0, 1.12, "out"), (10, 1, None)])]))
    bt_idle.to(bt_on, changed(doc, d("beat")), when(d("reducedMotion"), "boolean", value=False))
    bt_on.to(bt_idle, exit_at=100)
    # the table in place of the logo for 6 s every 20 s
    lay = sm.layer("Table Cycle")
    lay.state("Cycle", b.timeline("Table Cycle", 1200, [
        (logo_id, "opacity", "double", [(0, 1, None), (840, 1, "linear"), (852, 0, None), (1188, 0, "linear"),
                                        (1200, 1, None)]),
        (table_id, "opacity", "double", [(0, 0, None), (840, 0, "linear"), (852, 1, None), (1188, 1, "linear"),
                                         (1200, 0, None)])], loop="loop"))
    _ = blink
    return b


# ---------------------------------------------------------------------------
# The results (docs/RIVE.md, section 3 "Results", section 6)
# ---------------------------------------------------------------------------

def results_board(c, m, cv):
    doc = c.doc
    b = doc.board("ResultsOverlay", GRID_W, GRID_H, component=True, clip=False, machine="Results",
                  comment="ResultsOverlay: the tally's lines appearing as the world counts them (resStep), the\n"
                          "total, the grade stamped (resGrade), the best combo, the rank, the prompts.")
    d, u = m.d, m.u_
    sm = b.sm
    rm = d("reducedMotion")
    head = text(c, "Results Title", "RESULTS", DISP, 22, 20, 8, 0.0, 0, grad=CHROME, outline=PINK, ow=3, shadow=2,
                sem=semantics("text", "Results", headingLevel=1))
    sub = text(c, "Results Sub", "RUN COMPLETE", PIX, 8, 140, 22, color=CYAN)
    panel = shape(c, "Panel", slant(14, 46, 196, 150, 10), fill="C00C1448", stroke=PINK, sw=2)
    line_ids = []
    lines = []
    for i, (label, prop) in enumerate(TALLY):
        lid = doc.ids()
        y = 54 + i * 16
        n = node(c, "Tally %s" % label.title(), nid=lid, opacity=0)
        n.add(text(c, "%s Label" % label.title(), label, PIX, 8, 26, y, color=WHITE),
              text(c, "%s Value" % label.title(), "0", PIX, 8, 196, y, 1.0, 0, color=GOLD, bind_path=d(prop),
                   conv=cv.whole, sem=semantics("text", label.capitalize(), value=d(prop), value_conv=cv.whole,
                                                isHidden=True)))
        doc.link_sem(lid, c.last_sem)
        line_ids.append(lid)
        lines.append(n)
    tot_id = doc.ids()
    total = node(c, "Total", nid=tot_id, opacity=0)
    total.add(shape(c, "Total Rule", rect(176, 2), fill=PINK, x=22, y=134),
              text(c, "Total Label", "TOTAL", DISP, 14, 26, 148, 0, 0.5, color=WHITE, outline=BLACK),
              text(c, "Total Value", "0", PIX, 16, 200, 148, 1.0, 0.5, color=WHITE, outline=PINK,
                   bind_path=u("totalText"), sem=semantics("text", "Total", value=u("totalText"), isHidden=True)))
    doc.link_sem(tot_id, c.last_sem)
    stats_id = doc.ids()
    stats = node(c, "Stats", nid=stats_id, opacity=0)
    stats.add(text(c, "Best Combo Label", "BEST COMBO", PIX, 8, 26, 164, color=CYAN),
              text(c, "Best Combo Value", "0", PIX, 8, 196, 164, 1.0, 0, color=WHITE, bind_path=u("bestText"),
                   sem=semantics("text", "Best combo", value=u("bestText"), isHidden=True)))
    doc.link_sem(stats_id, c.last_sem)
    stats.add(
              text(c, "Air Label", "LONGEST AIR", PIX, 8, 26, 175, color=CYAN),
              text(c, "Air Value", "0.0S", PIX, 8, 196, 175, 1.0, 0, color=WHITE, bind_path=u("airText")),
              text(c, "Perfect Label", "PERFECT", PIX, 8, 26, 186, color=CYAN),
              text(c, "Perfect Value", "0", PIX, 8, 96, 186, 1.0, 0, color=GREEN, bind_path=d("resPerfects"),
                   conv=cv.whole),
              text(c, "Crash Label", "CRASH", PIX, 8, 116, 186, color=CYAN),
              text(c, "Crash Value", "0", PIX, 8, 196, 186, 1.0, 0, color=RED, bind_path=d("resCrashes"),
                   conv=cv.whole))

    # the grade stamp: a chrome letter slammed from 300 %, a 2-pixel shake, dust
    stamp_pos, stamp_id = doc.ids(), doc.ids()
    stamp = node(c, "Grade Stamp", nid=stamp_pos, x=262, y=118, opacity=0)
    stamp_in = node(c, "Stamp Slam", nid=stamp_id)
    letters = []
    for g, grad, ring in GRADES:
        lid = doc.ids()
        ln = node(c, "Grade " + g, nid=lid)
        ln.add(text(c, "Grade %s Letter" % g, g, DISP, 72, 0, 4, 0.5, 0.5, grad=grad, outline=BLACK, ow=4, shadow=3,
                    sem=semantics("text", "Grade %s" % g, isHidden=True, isLiveRegion=True)))
        doc.link_sem(stamp_pos, c.last_sem)
        letters.append((g, lid))
        stamp_in.add(ln)
    solo_id = doc.ids()
    solo = El("Solo", {"activeComponentId": letters[0][1], "name": "Grade Letters", "id": solo_id}, *stamp_in.kids)
    stamp_in.kids = [solo]
    stamp_in.add(shape(c, "Stamp Ring", El("Ellipse", {"width": 76, "height": 76, "name": "Path"}), fill="A0000000",
                       stroke=WHITE, sw=3))
    dust_id = doc.ids()
    dust = node(c, "Dust", nid=dust_id, opacity=0)
    for i, (dx, dy, s) in enumerate(((-44, 30, 6), (44, 30, 6), (-36, 38, 4), (38, 38, 4), (-52, 22, 3), (52, 20, 3),
                                     (0, 44, 5))):
        dust.add(shape(c, "Puff %d" % i, rect(s, s, 0.5, 0.5), fill="FFE8F0FF", x=dx, y=dy))
    stamp.add(text(c, "Rank Label", "RANK", PIX, 8, 0, -48, 0.5, 0.5, color=CYAN), dust, stamp_in)

    record_id = doc.ids()
    record = node(c, "Record", nid=record_id, opacity=0)
    record.add(text(c, "Record Text", "NEW RECORD!", DISP, 12, 262, 176, 0.5, 0.5, color=ORANGE, outline=BLACK,
                    sem=doc.link_sem(record_id, semantics("text", "New record", value=d("resRank"),
                                                          value_conv=cv.whole, isLiveRegion=True, isHidden=True))),
               text(c, "Record Place", "#", PIX, 8, 262, 190, 0.5, 0.5, color=WHITE,
                    runs=[("1", PIX, 8, WHITE, d("resRank"), cv.whole)]))
    prompts_id, pk_id, pp_id = doc.ids(), doc.ids(), doc.ids()
    prompts = node(c, "Prompts", nid=prompts_id, opacity=0)
    keys_p = node(c, "Prompts Keys", nid=pk_id)
    keys_p.add(text(c, "Prompt Again Keys", "ENTER/R: RIDE AGAIN", PIX, 8, 160, 210, 0.5, 0, color=GREEN,
                    sem=doc.link_sem(prompts_id, semantics("text", "Enter or R: ride again. Escape: menu",
                                                           isHidden=True))),
               text(c, "Prompt Menu Keys", "ESC: MENU", PIX, 8, 160, 222, 0.5, 0, color=WHITE))
    pad_p = node(c, "Prompts Pad", nid=pp_id, opacity=0)
    pad_p.add(text(c, "Prompt Again Pad", "START: RIDE AGAIN", PIX, 8, 160, 210, 0.5, 0, color=GREEN),
              text(c, "Prompt Menu Pad", "SELECT: MENU", PIX, 8, 160, 222, 0.5, 0, color=WHITE))
    prompts.add(keys_p, pad_p)
    b.add(head, sub, stamp, record, prompts, stats, total, *lines, panel)

    # Lines: each appears (0.35 s apart, as resStep grows) and pops
    rstep = d("resStep")
    for i, lid in enumerate(line_ids + [tot_id, stats_id]):
        lay = sm.layer("Line %d" % (i + 1))
        off = lay.state("Hidden", b.pose("Line %d Hidden" % (i + 1), [(lid, "opacity", "double", 0)]))
        on = lay.state("Shown", b.timeline("Line %d In" % (i + 1), 9, [
            (lid, "opacity", "double", [(0, 0, None), (2, 1, None)]),
            (lid, "x", "double", [(0, 24, "out"), (9, 0, None)])]))
        off.to(on, when(rstep, "number", "greaterThanOrEqual", i + 1))
        on.to(off, when(rstep, "number", "lessThan", i + 1))

    # Stamp: on resGrade >= 0, after 0.5 s, the letter slams
    lay = sm.layer("Stamp")
    s_off = lay.state("Hidden", b.pose("Stamp Hidden", [(stamp_pos, "opacity", "double", 0),
                                                       (dust_id, "opacity", "double", 0),
                                                       (prompts_id, "opacity", "double", 0)]))
    sf = 30 + 11
    s_in = lay.state("Slam", b.timeline("Stamp Slam", sf + 30, [
        (stamp_pos, "opacity", "double", [(0, 0, None), (30, 1, None)]),
        (stamp_id, "scaleX", "double", [(0, 3, None), (30, 3, "in"), (sf, 1, None)]),
        (stamp_id, "scaleY", "double", [(0, 3, None), (30, 3, "in"), (sf, 1, None)]),
        shake_track(stamp_pos, 262, sf, 2, 6),
        (dust_id, "opacity", "double", [(0, 0, None), (sf, 1, None), (sf + 24, 0, None)]),
        (dust_id, "scaleX", "double", [(0, 0.6, None), (sf, 0.6, "out"), (sf + 24, 1.5, None)]),
        (dust_id, "scaleY", "double", [(0, 0.6, None), (sf, 0.6, "out"), (sf + 24, 1.3, None)]),
        (prompts_id, "opacity", "double", [(0, 0, None), (sf + 20, 1, None)])]))
    s_fade = lay.state("Fade", b.timeline("Stamp Fade", 60, [
        (stamp_pos, "opacity", "double", [(0, 0, None), (30, 0, "linear"), (40, 1, None)]),
        (stamp_id, "scaleX", "double", [(0, 1, None)]), (stamp_id, "scaleY", "double", [(0, 1, None)]),
        (dust_id, "opacity", "double", [(0, 0, None)]),
        (prompts_id, "opacity", "double", [(0, 0, None), (50, 1, None)])]))
    stamped = when(d("resGrade"), "number", "greaterThanOrEqual", 0)
    s_off.to(s_in, stamped, when(rm, "boolean", value=False))
    s_off.to(s_fade, stamped, when(rm, "boolean", value=True))
    s_in.to(s_off, when(d("resGrade"), "number", "lessThan", 0))
    s_fade.to(s_off, when(d("resGrade"), "number", "lessThan", 0))
    # Grade: which letter
    lay = sm.layer("Grade")
    for gi, (g, lid) in enumerate(letters):
        st = lay.state("Grade " + g, b.pose("Grade " + g, [(solo_id, "activeComponentId", "id", lid)]))
        lay.any.to(st, when(d("resGrade"), "number", value=gi))
    # Record: the table's place, flashing
    lay = sm.layer("Record")
    r_off = lay.state("Hidden", b.pose("Record Hidden", [(record_id, "opacity", "double", 0)]))
    r_on = lay.state("Shown", b.timeline("Record Blink", 40, [
        (record_id, "opacity", "double", [(0, 1, None), (28, 0.35, None), (40, 0.35, None)])], loop="loop"))
    r_off.to(r_on, when(d("resRank"), "number", "greaterThan", 0), stamped)
    r_on.to(r_off, when(d("resRank"), "number", "lessThanOrEqual", 0))
    r_on.to(r_off, when(d("resGrade"), "number", "lessThan", 0))
    # Device: the prompts' glyphs follow the last device
    lay = sm.layer("Device")
    dk = lay.state("Keys", b.pose("Prompts Keys", [(pk_id, "opacity", "double", 1), (pp_id, "opacity", "double", 0)]))
    dp = lay.state("Pad", b.pose("Prompts Pad", [(pk_id, "opacity", "double", 0), (pp_id, "opacity", "double", 1)]))
    lay.any.to(dp, when(d("device"), "number", value=1))
    lay.any.to(dk, when(d("device"), "number", "notEqual", 1))
    return b


# ---------------------------------------------------------------------------
# The initials entry (docs/RIVE.md, section 6)
# ---------------------------------------------------------------------------

def initials_board(c, m, cv):
    doc = c.doc
    b = doc.board("InitialsOverlay", GRID_W, GRID_H, component=True, clip=False, machine="Initials",
                  comment="InitialsOverlay: three big letters, the caret under the cursor's (ui/initials.as and\n"
                          "ui/pad.as move them), the table with the new row flashing.")
    d, u = m.d, m.u_
    sm = b.sm
    head = text(c, "Initials Title", "NEW HIGH SCORE!", DISP, 18, 160, 8, 0.5, 0, grad=PINK_CHROME, outline=WHITE,
                ow=2, shadow=2, sem=semantics("text", "New high score", headingLevel=1))
    sub = text(c, "Initials Sub", "ENTER YOUR INITIALS", PIX, 8, 160, 32, 0.5, 0, color=CYAN)
    letters = node(c, "Letters")
    for i in range(3):
        x = 112 + 48 * i
        letters.add(text(c, "Letter %d" % (i + 1), "A", DISP, 36, x, 66, 0.5, 0.5, grad=CHROME, outline=PINK, ow=3,
                         shadow=2, bind_path=u("iniText%d" % i), sem=semantics("text", "Letter %d" % (i + 1))),
                    shape(c, "Letter Box %d" % (i + 1), slant(x - 20, 46, 38, 40, 4), fill=DEEP, stroke=WHITE, sw=2))
    caret_id = doc.ids()
    caret = El("Node", {"x": 112, "name": "Caret", "id": caret_id})
    caret_in = node(c, "Caret Bar", x=0)
    caret_in.add(shape(c, "Caret Shape", slant(-16, 90, 34, 4, 1), fill=GREEN),
                 shape(c, "Up", poly([(0, 40), (5, 34), (-5, 34)]), fill=GREEN, y=0) if False else None)
    caret.add(El("Node", {"name": "Caret Offset", "id": doc.ids()}, bind(u("iniCursor"), 13, cv.caret_x), caret_in))
    blink_id = caret_in.get("id")
    hint = text(c, "Initials Hint", "UP/DOWN: LETTER  ENTER: OK", PIX, 8, 160, 102, 0.5, 0, color=WHITE)
    table = node(c, "Table", x=0, y=0)
    for i in range(1, 11):
        y = 120 + (i - 1) * 10
        col = WHITE if i <= 3 else "FFC8D0E0"
        table.add(text(c, "Rank %d" % i, "%d." % i if i < 10 else "10", PIX, 8, 88, y, 1.0, 0, color=PINK, shadow=0),
                  text(c, "Name %d" % i, "AVA", PIX, 8, 96, y, color=col, bind_path=u("hs%dName" % i), shadow=0),
                  text(c, "Pts %d" % i, "45,000", PIX, 8, 208, y, 1.0, 0, color=col, bind_path=u("hs%dPts" % i),
                       shadow=0),
                  text(c, "Grade %d" % i, "S", PIX, 8, 216, y, color=GREEN, bind_path=u("hs%dGrade" % i), shadow=0))
    hl_id = doc.ids()
    hl = El("Node", {"opacity": 0, "name": "New Row", "id": hl_id})
    hl.add(El("Node", {"name": "New Row Offset", "id": doc.ids()}, bind(d("resRank"), 14, cv.rank_y),
              shape(c, "New Row Bar", slant(76, 109, 168, 10, 2), fill=PINK)))
    plate = shape(c, "Table Plate", slant(70, 114, 180, 106, 6), fill="C80C1448", stroke=CYAN, sw=1)
    saved_id = doc.ids()
    saved = text(c, "Saved", "SAVED!", DISP, 16, 160, 66, 0.5, 0.5, color=GREEN, outline=BLACK, shadow=2, nid=saved_id,
                 opacity=0, sem=semantics("text", "Initials saved", isLiveRegion=True))
    b.add(head, sub, saved, caret, letters, hint, table, hl, plate)

    lay = sm.layer("Caret Blink")
    lay.state("Blink", b.timeline("Caret Blink", 30, [(blink_id, "opacity", "double", [(0, 1, None), (18, 0, None)])],
                                   loop="loop"))
    lay = sm.layer("New Row")
    off = lay.state("Hidden", b.pose("New Row Hidden", [(hl_id, "opacity", "double", 0)]))
    on = lay.state("Flash", b.timeline("New Row Flash", 20, [(hl_id, "opacity", "double", [(0, 0.8, None), (10, 0.3, None)])],
                                       loop="loop"))
    off.to(on, when(d("resRank"), "number", "greaterThan", 0))
    on.to(off, when(d("resRank"), "number", "lessThanOrEqual", 0))
    lay = sm.layer("Done")
    nd = lay.state("Entering", b.pose("Entering", [(saved_id, "opacity", "double", 0), (caret_id, "opacity", "double", 1)]))
    dn = lay.state("Saved", b.pose("Saved", [(saved_id, "opacity", "double", 1), (caret_id, "opacity", "double", 0)]))
    lay.any.to(dn, when(u("iniDone"), "boolean", value=True))
    lay.any.to(nd, when(u("iniDone"), "boolean", value=False))
    return b


# ---------------------------------------------------------------------------
# The pause menu (docs/RIVE.md, section 6)
# ---------------------------------------------------------------------------

def pause_board(c, m, cv):
    doc = c.doc
    b = doc.board("PauseOverlay", GRID_W, GRID_H, component=True, clip=False, machine="Pause",
                  comment="PauseOverlay: a slanted panel, its items in the display face, the volumes as 10-step\n"
                          "bars; Main's listeners (keys) and ui/pad.as move Game/ui/pauseSel and fire pauseGo,\n"
                          "pauseLeft, pauseRight, which Main's layer Pause Act turns into commands.")
    d, u = m.d, m.u_
    sm = b.sm
    top = PAUSE_TOP
    dialog_sem = doc.ids()
    step = PAUSE_STEP
    title = text(c, "Pause Title", "PAUSED", DISP, 24, 160, 8, 0.5, 0, grad=CHROME, outline=PINK, ow=3, shadow=2,
                 sem=semantics("text", "Paused", headingLevel=1))
    sel_bar = El("Node", {"name": "Selection", "id": doc.ids()}, bind(u("pauseSel"), 14, cv.pause_y),
                 text(c, "Cursor", ">", PIX, 8, 72, top - 4, color=WHITE, shadow=1),
                 shape(c, "Selection Bar", slant(66, top - 6, 184, 13, 3), fill=PINK))
    items = node(c, "Items")
    toggles = []
    for i, (key, label, kind, target) in enumerate(PAUSE_ITEMS):
        y = top + i * step
        path = None if target is None else (m.d(target[1]) if target[0] == "data" else m.u_(target[1]))
        if kind == "volume":
            sem = semantics("slider", label.capitalize() + " volume", value=path, value_conv=cv.percent)
        elif kind == "toggle":
            sem = semantics("switchControl", label.capitalize())
            sem.add(bind(path, 1000))
        else:
            sem = semantics("button", label.capitalize())
        items.add(text(c, "Item " + label.title(), label, DISP, 9, 82, y, 0, 0.5, color=WHITE, outline=BLACK, ow=2,
                       shadow=1, sem=sem))
        if kind == "volume":
            bars = node(c, label.title() + " Bars", x=192, y=y - 4)
            for k in range(10):
                bars.add(shape(c, "Gap %d" % k, rect(1, 8), fill=DEEP, x=5 * k + 4))
            bars.add(El("Shape", {"name": "Lit", "id": doc.ids()}, rect(0, 8, bind_w=(path, 20, cv.vol_bars)),
                        El("Fill", {"name": "Fill"}, El("SolidColor", {"colorValue": GREEN, "name": "C"}))),
                     shape(c, "Unlit", rect(50, 8), fill=DIM, stroke=BLACK, sw=1))
            items.add(bars)
        elif kind == "toggle":
            on_id, off_id = doc.ids(), doc.ids()
            items.add(text(c, label.title() + " On", "ON", PIX, 8, 242, y - 4, 1.0, 0, color=GREEN, nid=on_id),
                      text(c, label.title() + " Off", "OFF", PIX, 8, 242, y - 4, 1.0, 0, color=GREY, nid=off_id,
                           opacity=0))
            toggles.append((label, path, on_id, off_id))
    hint_k_id, hint_p_id = doc.ids(), doc.ids()
    hint_k = text(c, "Pause Hint Keys", "ENTER: SELECT  ESC: RESUME", PIX, 8, 160, 204, 0.5, 0, color=CYAN, nid=hint_k_id)
    hint_p = text(c, "Pause Hint Pad", "A: SELECT  B: RESUME", PIX, 8, 160, 204, 0.5, 0, color=CYAN, nid=hint_p_id,
                  opacity=0)
    # the controls card (docs/SPEC.md, section 3): the last device's mapping
    card_id, ck_id, cp_id = doc.ids(), doc.ids(), doc.ids()
    card = node(c, "Controls Card", nid=card_id, opacity=0)
    ck = node(c, "Controls Keys", nid=ck_id)
    cp = node(c, "Controls Pad", nid=cp_id, opacity=0)
    for holder, rows in ((ck, CONTROLS_KEYS), (cp, CONTROLS_PAD)):
        for r, (what, how) in enumerate(rows):
            y = 52 + r * 13
            holder.add(text(c, "Control " + what.title(), what, PIX, 8, 70, y, color=CYAN, shadow=1),
                       text(c, "Mapping " + what.title(), how, PIX, 8, 250, y, 1.0, 0, color=WHITE, shadow=1))
    card.add(text(c, "Controls Title", "CONTROLS", DISP, 16, 160, 20, 0.5, 0, color=WHITE, outline=PINK, shadow=2,
                  sem=doc.link_sem(card_id, semantics("text", "Controls", isHidden=True))),
             ck, cp,
             text(c, "Controls Close", "ENTER: BACK", PIX, 8, 160, 172, 0.5, 0, color=GREEN, shadow=1),
             shape(c, "Card", slant(52, 12, 212, 176, 10), fill=BLACK, stroke=CYAN, sw=3))
    panel = shape(c, "Panel", slant(56, 10, 196, 186, 14), fill=DEEP, stroke=PINK, sw=3)
    panel_shadow = shape(c, "Panel Shadow", slant(60, 14, 196, 186, 14), fill=BLACK)
    dim = shape(c, "Dim", rect(GRID_W + 2000, GRID_H + 2000), fill=HALF, x=-1000, y=-1000)
    root = node(c, "Pause Root")
    root.add(card, title, items, sel_bar, hint_k, hint_p, panel, panel_shadow, dim,
             El("SemanticData", {"role": "dialog", "label": "Pause menu", "isModal": True, "isHidden": True, "name": "Semantics", "id": dialog_sem}))
    b.add(root)
    # the dialog in the semantics only while paused (Main moves the overlay away otherwise)
    lay = sm.layer("Shown")
    sh_off = lay.state("Closed", b.pose("Dialog Closed", [(dialog_sem, "isHidden", "bool", True)]))
    sh_on = lay.state("Open", b.pose("Dialog Open", [(dialog_sem, "isHidden", "bool", False)]))
    lay.any.to(sh_on, when(d("paused"), "boolean", value=True))
    lay.any.to(sh_off, when(d("paused"), "boolean", value=False))
    for label, path, on_id, off_id in toggles:
        lay = sm.layer("Toggle " + label.title())
        on = lay.state("On", b.pose(label.title() + " On", [(on_id, "opacity", "double", 1), (off_id, "opacity", "double", 0)]))
        off = lay.state("Off", b.pose(label.title() + " Off", [(on_id, "opacity", "double", 0), (off_id, "opacity", "double", 1)]))
        lay.any.to(on, when(path, "boolean", value=True))
        lay.any.to(off, when(path, "boolean", value=False))
    lay = sm.layer("Controls Card")
    cc_off = lay.state("Hidden", b.pose("Card Hidden", [(card_id, "opacity", "double", 0)]))
    cc_on = lay.state("Shown", b.timeline("Card In", 9, [(card_id, "opacity", "double", [(0, 1, None)]),
                                                        (card_id, "x", "double", [(0, 60, "out"), (9, 0, None)])]))
    cc_off.to(cc_on, when(u("controls"), "boolean", value=True))
    cc_on.to(cc_off, when(u("controls"), "boolean", value=False))
    lay = sm.layer("Device")
    dk = lay.state("Keys", b.pose("Hint Keys", [(hint_k_id, "opacity", "double", 1), (hint_p_id, "opacity", "double", 0),
                                                (ck_id, "opacity", "double", 1), (cp_id, "opacity", "double", 0)]))
    dp = lay.state("Pad", b.pose("Hint Pad", [(hint_k_id, "opacity", "double", 0), (hint_p_id, "opacity", "double", 1),
                                              (ck_id, "opacity", "double", 0), (cp_id, "opacity", "double", 1)]))
    lay.any.to(dp, when(d("device"), "number", value=1))
    lay.any.to(dk, when(d("device"), "number", "notEqual", 1))
    return b


# ---------------------------------------------------------------------------
# The wipe and the captions
# ---------------------------------------------------------------------------

def wipe_board(c, m, cv):
    doc = c.doc
    b = doc.board("Wipe", GRID_W, GRID_H, component=True, clip=False, machine="Wipe",
                  comment="Wipe: the snow wipe covering a respawn (RIDER.md, section 9): 1.0 s after crashSeq, in\n"
                          "0.15 s, out 0.15 s; a fade with reduced motion. Drawn past the grid to the window's edge.")
    d = m.d
    sm = b.sm
    w_id = doc.ids()
    sheet = node(c, "Snow", nid=w_id, x=-3000)
    sheet.add(shape(c, "Snow Edge Pink", slant(-40, -800, 30, 1840, -60), fill=PINK),
              shape(c, "Snow Edge Cyan", slant(-60, -800, 14, 1840, -60), fill=CYAN))
    # the spray ahead of the edge, and a dither of blue-white flakes on the
    # sheet where it covers the grid (local x 1100..1420 while it holds)
    for i in range(24):
        fy = (i * 37) % 280 - 20
        fx = -70 - (i * 29) % 90 + fy * 60 // 1840
        s = 2 + (i % 3) * 2
        sheet.add(shape(c, "Spray %d" % i, rect(s, s), fill="FFF4F8FF", x=fx, y=fy))
    for i in range(90):
        fx = 1060 + (i * 53) % 420
        fy = (i * 97) % 280 - 20
        sheet.add(shape(c, "Flake %d" % i, rect(2 + (i % 2), 2 + (i % 2)), fill="FFB8CCEC", x=fx, y=fy))
    sheet.add(text(c, "Wipe Word", "RESPAWN", DISP, 20, 1260, 120, 0.5, 0.5, color=CYAN, outline=NAVY, shadow=2))
    sheet.add(shape(c, "Snow Sheet", slant(-10, -800, 2400, 1840, -60), fill="FFF4F8FF"))
    b.add(sheet)
    lay = sm.layer("Wipe")
    idle = lay.state("Idle", b.pose("Wipe Idle", [(w_id, "x", "double", -3000), (w_id, "opacity", "double", 1)]))
    run = lay.state("Wipe", b.timeline("Wipe Run", 60 + 9 + 12 + 9, [
        (w_id, "opacity", "double", [(0, 1, None)]),
        (w_id, "x", "double", [(0, 400, None), (60, 400, "linear"), (69, -1100, None), (81, -1100, "linear"),
                               (90, -2600, None)])]))
    fade = lay.state("Fade", b.timeline("Wipe Fade", 90, [
        (w_id, "x", "double", [(0, -1100, None)]),
        (w_id, "opacity", "double", [(0, 0, None), (60, 0, "linear"), (69, 1, None), (81, 1, "linear"), (90, 0, None)])]))
    crash = changed(doc, d("crashSeq"))
    idle.to(run, crash, when(d("reducedMotion"), "boolean", value=False))
    idle.to(fade, crash, when(d("reducedMotion"), "boolean", value=True))
    run.to(idle, exit_at=100)
    fade.to(idle, exit_at=100)
    return b


def captions_board(c, m, cv):
    doc = c.doc
    b = doc.board("Captions", GRID_W, GRID_H, component=True, clip=False, machine="Captions",
                  comment="Captions: one line at the bottom for the announcer's lines (captionLine, captionSeq;\n"
                          "ui/lines.as's table), 3 s each, when Game/ui/captions.")
    d, u = m.d, m.u_
    sm = b.sm
    cap_id = doc.ids()
    cap = node(c, "Caption", nid=cap_id, opacity=0)
    cap.add(text(c, "Caption Text", "", PIX, 8, 160, 204, 0.5, 0, color=WHITE, shadow=1, bind_path=u("captionText"),
                 sem=doc.link_sem(cap_id, semantics("text", bind_label=u("captionText"), isLiveRegion=True, isHidden=True))),
            shape(c, "Caption Plate", slant(36, 200, 248, 16, 4), fill="B0000000"))
    b.add(cap)
    lay = sm.layer("Captions")
    hidden = lay.state("Hidden", b.pose("Caption Hidden", [(cap_id, "opacity", "double", 0)]))
    a = lay.state("Line A", b.timeline("Caption A", 180, [(cap_id, "opacity", "double", [(0, 1, None), (170, 1, "linear"),
                                                                                         (180, 0, None)])]))
    bb = lay.state("Line B", b.timeline("Caption B", 180, [(cap_id, "opacity", "double", [(0, 1, None), (170, 1, "linear"),
                                                                                          (180, 0, None)])]))
    show = [changed(doc, d("captionSeq")), when(u("captions"), "boolean", value=True),
            when(d("captionLine"), "number", "greaterThanOrEqual", 0)]
    hidden.to(a, *show)
    a.to(bb, *[changed(doc, d("captionSeq")), when(u("captions"), "boolean", value=True),
               when(d("captionLine"), "number", "greaterThanOrEqual", 0)])
    bb.to(a, *[changed(doc, d("captionSeq")), when(u("captions"), "boolean", value=True),
               when(d("captionLine"), "number", "greaterThanOrEqual", 0)])
    a.to(hidden, exit_at=100)
    bb.to(hidden, exit_at=100)
    a.to(hidden, when(u("captions"), "boolean", value=False))
    bb.to(hidden, when(u("captions"), "boolean", value=False))
    return b


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main_board(c, m, cv, boards, scripts):
    doc = c.doc
    g = m.g
    d, u = m.d, m.u_
    b = doc.board("Main", 960, 720, vm=g, machine="Main",
                  comment="Main: the window. The Scene3D fills it; the Grid (the overlays at the whole scale\n"
                          "ui/fit.as works out, centred) over it; the 2D scripts. docs/RIVE.md, sections 1 and 3.")
    b.style = {"layoutAlignmentType": "topLeft"}

    # the 2D scripts (draw nothing): the strings, the pad, the initials' keys
    initials_id = doc.ids()
    scripts_node = node(c, "Scripts")
    scripts_node.add(El("ScriptedDrawable", {"scriptAssetId": scripts["trick_text"], "name": "Trick Text",
                                             "id": doc.ids()}),
                     El("ScriptedDrawable", {"scriptAssetId": scripts["pad"], "name": "Pad", "id": doc.ids()}),
                     El("ScriptedDrawable", {"scriptAssetId": scripts["initials"], "name": "Initials Keys",
                                             "id": initials_id},
                        El("FocusData", {"canTraverse": False, "name": "Keys"})))

    # the Grid: 320 x 240 at the whole scale, centred
    grid_id = doc.ids()
    grid = El("Node", {"name": "Grid", "id": grid_id},
              bind(u("gx"), 13), bind(u("gy"), 14), bind(u("scale"), 16), bind(u("scale"), 17))
    pause_id, blank_id, solo_id = doc.ids(), doc.ids(), doc.ids()
    screen_ids = {k: doc.ids() for k in ("title", "hud", "results", "initials")}
    q = None
    pause_n = nested(c, boards["pause"], "Pause", nid=pause_id, quantize=q)
    pause_n.set("opacity", 0)
    pause_n.set("x", AWAY)
    solo = El("Solo", {"activeComponentId": screen_ids["title"], "name": "Screens", "id": solo_id},
              nested(c, boards["title"], "Title", nid=screen_ids["title"], quantize=q),
              nested(c, boards["hud"], "Hud", nid=screen_ids["hud"], quantize=q),
              nested(c, boards["results"], "Results", nid=screen_ids["results"], quantize=q),
              nested(c, boards["initials"], "Initials", nid=screen_ids["initials"], quantize=q),
              El("Node", {"name": "No Screen", "id": blank_id}))
    grid_sem = doc.ids()
    grid.add(pause_n, nested(c, boards["wipe"], "Wipe"), nested(c, boards["captions"], "Captions"), solo,
             semantics("group", "Avalanche Air", sid=grid_sem))

    # the layout: the fit script, the menus' key holders, the Scene3D
    fit_box = box(doc, "Fit Box", w="fill", h="fill", inset={"top": 0, "right": 0, "bottom": 0, "left": 0})
    fit_box.add(El("ScriptedLayout", {"scriptAssetId": scripts["fit"], "name": "Fit", "id": doc.ids()}))
    keys = {}
    key_boxes = []
    for k in ("title", "results", "pause"):
        kid = doc.ids()
        kb = box(doc, "%s Keys" % k.title(), w=1, h=1, inset={"top": 0, "left": 0}, bid=kid)
        kb.add(El("FocusData", {"canTraverse": False, "name": "Keys"}))
        keys[k] = kid
        key_boxes.append(kb)
    stage = box(doc, "Stage", w="fill", h="fill", inset={"top": 0, "right": 0, "bottom": 0, "left": 0},
                fill=BLACK)
    scene_id = doc.ids()
    if c.preview:
        # (a 2D-only preview: a snowy backdrop where the 3D goes, holding the keys)
        fake = box(doc, "Scene3D", w="fill", h="fill", bid=scene_id)
        fake.add(El("FocusData", {"canTraverse": False, "name": "Keys"}),
                 El("Fill", {"name": "Fill"}, El("LinearGradient", {"startX": 0, "startY": 0, "endX": 0, "endY": 720,
                                                                    "name": "Sky"},
                                                 *[El("GradientStop", {"colorValue": col, "position": pos, "name": "S"})
                                                   for pos, col in ((0, "FF5878C0"), (0.5, "FFC8D8F0"),
                                                                    (0.52, "FFE8E0E8"), (1, "FFB0A8C0"))])))
        stage.add(fake)
    else:
        stage.add(El("ScriptedLayout", {"scriptAssetId": SCENE3D, "name": "Scene3D", "id": scene_id},
                     El("FocusData", {"canTraverse": False, "name": "Keys"})),
                  semantics("image", "The mountain: the run in 3D"))
    root = box(doc, "Root", w="fill", h="fill", inset={"top": 0, "right": 0, "bottom": 0, "left": 0})
    root.add(fit_box, *key_boxes, stage)

    b.add(scripts_node, grid, root)
    sm = b.sm

    plus = lambda path: write_from(doc, path, path, "number", cv.plus1)  # noqa: E731
    dev0 = set_value(d("device"), "number", 0)

    # --- the keys (docs/RIVE.md, section 3): on the node holding the focus
    tk = keys["title"]
    sm.listen("Title Start", tk, on_keys("enter", "space", "kpEnter", "r"), plus(d("startSeq")), plus(d("uiSelectSeq")),
              dev0)
    sm.listen("Title Left", tk, on_keys("left", "a", phase=3), write_from(doc, d("scheme"), d("scheme"), "number",
                                                                          cv.prev3), plus(d("uiMoveSeq")), dev0)
    sm.listen("Title Right", tk, on_keys("right", "d", phase=3), write_from(doc, d("scheme"), d("scheme"), "number",
                                                                            cv.next3), plus(d("uiMoveSeq")), dev0)
    # the run: the Scene3D holds the keys (the world reads them); R restarts, Escape pauses
    sm.listen("Run Restart", scene_id, on_keys("r"), plus(d("restartSeq")), dev0)
    sm.listen("Run Pause", scene_id, on_keys("escape"), set_value(u("pauseSel"), "number", 0),
              set_value(d("paused"), "boolean", True), plus(d("uiSelectSeq")), dev0)
    rk = keys["results"]
    sm.listen("Results Again", rk, on_keys("enter", "space", "kpEnter", "r"), plus(d("restartSeq")),
              plus(d("uiSelectSeq")), dev0)
    sm.listen("Results Menu", rk, on_keys("escape"), set_value(u("pauseSel"), "number", 0),
              set_value(d("paused"), "boolean", True), plus(d("uiSelectSeq")), dev0)
    pk = keys["pause"]
    sm.listen("Pause Up", pk, on_keys("up", "w", phase=3), write_from(doc, u("pauseSel"), u("pauseSel"), "number",
                                                                      cv.pause_prev), plus(d("uiMoveSeq")), dev0)
    sm.listen("Pause Down", pk, on_keys("down", "s", phase=3), write_from(doc, u("pauseSel"), u("pauseSel"), "number",
                                                                          cv.pause_next), plus(d("uiMoveSeq")), dev0)
    sm.listen("Pause Left", pk, on_keys("left", "a", phase=3), fire(u("pauseLeft")), dev0)
    sm.listen("Pause Right", pk, on_keys("right", "d", phase=3), fire(u("pauseRight")), dev0)
    sm.listen("Pause Select", pk, on_keys("enter", "space", "kpEnter"), fire(u("pauseGo")), dev0)
    sm.listen("Pause Back", pk, on_keys("escape", "backspace"), fire(u("pauseBack")), dev0)

    not_demo = when(d("demo"), "boolean", value=False)
    is_demo = when(d("demo"), "boolean", value=True)
    ph = d("phase")
    in_run = [when(ph, "number", "greaterThanOrEqual", 1), when(ph, "number", "lessThanOrEqual", 5)]

    # Screen: which overlay the Solo shows, by `phase`; none in demo mode
    lay = sm.layer("Screen")
    for name, key, conds in (("Title", "title", [when(ph, "number", value=0)]), ("Run", "hud", in_run),
                             ("Results", "results", [when(ph, "number", value=6)]),
                             ("Initials", "initials", [when(ph, "number", value=7)])):
        st = lay.state(name, b.pose("Screen " + name, [(solo_id, "activeComponentId", "id", screen_ids[key])]))
        lay.any.to(st, not_demo, *conds)
    st = lay.state("Demo", b.pose("Screen Demo", [(solo_id, "activeComponentId", "id", blank_id)]))
    lay.any.to(st, is_demo)

    # Pause: the Scene3D stops (`playing` false), the PauseOverlay shows
    lay = sm.layer("Pause")
    p_off = lay.state("Off", b.pose("Pause Off", [(pause_id, "opacity", "double", 0), (pause_id, "x", "double", AWAY)]),
                      actions=[set_value(g.path("playing"), "boolean", True), set_value(u("controls"), "boolean", False)])
    p_on = lay.state("On", b.pose("Pause On", [(pause_id, "opacity", "double", 1), (pause_id, "x", "double", 0)]),
                     actions=[set_value(g.path("playing"), "boolean", False)])
    lay.any.to(p_on, when(d("paused"), "boolean", value=True), not_demo)
    lay.any.to(p_off, when(d("paused"), "boolean", value=False))
    lay.any.to(p_off, is_demo)

    # Pause Act: the selected row's command on Enter / south, Left / Right
    # (the controls card, while shown, takes Enter and Escape to close it;
    # Escape otherwise resumes)
    lay = sm.layer("Pause Act")
    idle = lay.state("Idle")
    go, left, right, back = u("pauseGo"), u("pauseLeft"), u("pauseRight"), u("pauseBack")
    sel = u("pauseSel")
    card_off = when(u("controls"), "boolean", value=False)
    card_on = when(u("controls"), "boolean", value=True)
    st = lay.state("Back Resume", actions=[set_value(d("paused"), "boolean", False), plus(d("uiBackSeq"))])
    idle.to(st, when(back, "trigger"), card_off)
    st.to(idle)
    st = lay.state("Close Controls", actions=[set_value(u("controls"), "boolean", False), plus(d("uiBackSeq"))])
    idle.to(st, when(back, "trigger"), card_on)
    idle.to(st, when(go, "trigger"), card_on)
    st.to(idle)
    for i, (key, label, kind, target) in enumerate(PAUSE_ITEMS):
        is_sel = when(sel, "number", value=i)
        if kind == "action":
            if key == "resume":
                acts = [set_value(d("paused"), "boolean", False), plus(d("uiBackSeq"))]
            elif key == "restart":
                acts = [plus(d("restartSeq")), set_value(d("paused"), "boolean", False), plus(d("uiSelectSeq"))]
            elif key == "controls":
                acts = [set_value(u("controls"), "boolean", True), plus(d("uiSelectSeq"))]
            else:
                acts = [plus(d("quitSeq")), set_value(d("paused"), "boolean", False), plus(d("uiSelectSeq"))]
            st = lay.state(label.title(), actions=acts)
            idle.to(st, when(go, "trigger"), is_sel, card_off)
            st.to(idle)
        elif kind == "volume":
            path = d(target[1])
            up = lay.state(label.title() + " Up", actions=[write_from(doc, path, path, "number", cv.vol_up),
                                                           plus(d("uiMoveSeq"))])
            dn = lay.state(label.title() + " Down", actions=[write_from(doc, path, path, "number", cv.vol_down),
                                                             plus(d("uiMoveSeq"))])
            idle.to(up, when(right, "trigger"), is_sel, card_off)
            idle.to(up, when(go, "trigger"), is_sel, card_off)
            idle.to(dn, when(left, "trigger"), is_sel, card_off)
            up.to(idle)
            dn.to(idle)
        else:
            path = d(target[1]) if target[0] == "data" else u(target[1])
            fl = lay.state(label.title() + " Flip", actions=[write_from(doc, path, path, "boolean", cv.notc),
                                                             plus(d("uiSelectSeq"))])
            for t in (go, left, right):
                idle.to(fl, when(t, "trigger"), is_sel, card_off)
            fl.to(idle)

    # Focus: the Scene3D during the run, the shown menu otherwise, nothing in demo mode
    lay = sm.layer("Focus")
    paused_t = when(d("paused"), "boolean", value=True)
    paused_f = when(d("paused"), "boolean", value=False)
    target = lambda nid: [El("FocusActionTarget", {"targetId": nid})]  # noqa: E731
    st = lay.state("Focus Title", actions=target(keys["title"]))
    lay.any.to(st, not_demo, paused_f, when(ph, "number", value=0))
    st = lay.state("Focus Run", actions=target(scene_id))
    lay.any.to(st, not_demo, paused_f, *in_run)
    st = lay.state("Focus Results", actions=target(keys["results"]))
    lay.any.to(st, not_demo, paused_f, when(ph, "number", value=6))
    st = lay.state("Focus Initials", actions=target(initials_id))
    lay.any.to(st, not_demo, paused_f, when(ph, "number", value=7))
    st = lay.state("Focus Pause", actions=target(keys["pause"]))
    lay.any.to(st, not_demo, paused_t)
    st = lay.state("Focus None", actions=[El("FocusActionClear")])
    lay.any.to(st, is_demo)

    # Demo: every overlay hidden (and out of the semantics), input ignored
    lay = sm.layer("Demo")
    shown = lay.state("Shown", b.pose("Grid Shown", [(grid_id, "opacity", "double", 1),
                                                     (grid_sem, "isHidden", "bool", False)]))
    hidden = lay.state("Hidden", b.pose("Grid Hidden", [(grid_id, "opacity", "double", 0),
                                                        (grid_sem, "isHidden", "bool", True)]))
    lay.any.to(hidden, is_demo)
    lay.any.to(shown, not_demo)
    return b


# ---------------------------------------------------------------------------
# The document
# ---------------------------------------------------------------------------

SCRIPTS = ["fit", "trick_text", "pad", "initials"]


def build(preview=False):
    rows = "export const PAUSE_ROWS: i32 = %d;" % len(PAUSE_ITEMS)
    if rows not in open(os.path.join(ROOT, "ui", "ui_state.as")).read():
        sys.exit("ui/ui_state.as: PAUSE_ROWS must be %d (make_rml.py PAUSE_ITEMS)" % len(PAUSE_ITEMS))
    c = Ctx(preview)
    doc = c.doc
    m = Models(c)
    cv = Conv(c)
    scripts = {}
    for s in SCRIPTS:
        scripts[s] = doc.ids()
        doc.root(El("ScriptAsset", {"file": "ui/%s.as" % s, "name": s, "id": scripts[s]}))
    boards = {
        "title": title_board(c, m, cv),
        "hud": hud_board(c, m, cv),
        "results": results_board(c, m, cv),
        "initials": initials_board(c, m, cv),
        "pause": pause_board(c, m, cv),
        "wipe": wipe_board(c, m, cv),
        "captions": captions_board(c, m, cv),
    }
    main = main_board(c, m, cv, boards, scripts)
    # (Main first in the file: the editor lays the artboards out in this order;
    # rive.yaml names it the default)
    doc.boards.remove(main)
    doc.boards.insert(0, main)
    return doc.render("Generated by make_rml.py: do not edit (docs/RIVE.md).")


def copy_fonts():
    """fonts/ holds the two faces and their licences (committed; fetched from
    Google Fonts' repository by tools/make_ui_fonts.py): the missing ones."""
    missing = [dst for dst, _ in FONT_FILES if not os.path.exists(os.path.join(ROOT, "fonts", dst))]
    return missing


def write_preview(out_dir):
    out_dir = os.path.abspath(out_dir)
    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, "preview.rml"), "w") as f:
        f.write(build(preview=True))
    with open(os.path.join(out_dir, "rive.yaml"), "w") as f:
        f.write("name: preview\nmain: Main\nscripting: wasm\n")
    for sub in ("ui", "fonts"):
        dst = os.path.join(out_dir, sub)
        if os.path.exists(dst):
            shutil.rmtree(dst)
        shutil.copytree(os.path.join(ROOT, sub), dst)
    print("wrote %s" % os.path.relpath(out_dir, ROOT))


def main():
    if "--preview" in sys.argv:
        write_preview(sys.argv[sys.argv.index("--preview") + 1])
        return
    missing = copy_fonts()
    if missing:
        print("missing fonts/%s: run python3 tools/make_ui_fonts.py" % ", ".join(missing))
    path = os.path.join(ROOT, "avalanche.rml")
    text_ = build()
    old = open(path).read() if os.path.exists(path) else None
    if "--check" in sys.argv:
        sys.exit(0 if old == text_ else 1)
    if old != text_:
        with open(path, "w") as f:
            f.write(text_)
        print("wrote avalanche.rml")


if __name__ == "__main__":
    main()
