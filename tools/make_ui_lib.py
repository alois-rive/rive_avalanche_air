"""make_ui_lib: the RML builders make_rml.py writes Avalanche Air's Rive side
with (docs/RIVE.md).

Vendored and trimmed from the Hedra samples' shared UI library
(rive_modeler/samples/ui/rml_ui.py): its XML writer, view models, state
machine builders (conditions, listener actions, layers) and layout boxes.
The samples' design system (Inter, Iosevka, frosted glass) is NOT here:
this game draws in the 1998 tokens of make_rml.py (docs/LOOK.md, section 8).
Standard library only; the same input writes the same bytes.
"""

# ---------------------------------------------------------------------------
# XML
# ---------------------------------------------------------------------------


def fmt(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return "%d" % v
    if isinstance(v, float):
        if abs(v - round(v)) < 1e-9:
            return "%d" % round(v)
        return ("%.4f" % v).rstrip("0").rstrip(".")
    return str(v)


def esc(s):
    return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
            .replace('"', "&quot;").replace("\n", "&#10;"))


class El:
    """An RML element: a tag, ordered attributes, children."""

    __slots__ = ("tag", "attrs", "kids")

    def __init__(self, tag, attrs=None, *kids):
        self.tag = tag
        self.attrs = [(k, v) for k, v in (attrs or {}).items() if v is not None]
        self.kids = [k for k in kids if k is not None]

    def add(self, *kids):
        self.kids.extend(k for k in kids if k is not None)
        return self

    def get(self, key):
        for k, v in self.attrs:
            if k == key:
                return v
        return None

    def set(self, key, value):
        for i, (k, _) in enumerate(self.attrs):
            if k == key:
                self.attrs[i] = (key, value)
                return self
        self.attrs.insert(0, (key, value))
        return self

    def write(self, out, ind):
        attrs = "".join(' %s="%s"' % (k, esc(fmt(v))) for k, v in self.attrs)
        if not self.kids:
            out.append("%s<%s%s/>" % (ind, self.tag, attrs))
            return
        out.append("%s<%s%s>" % (ind, self.tag, attrs))
        for k in self.kids:
            k.write(out, ind + "    ")
        out.append("%s</%s>" % (ind, self.tag))


class Comment:
    __slots__ = ("text",)

    def __init__(self, text):
        self.text = text

    def write(self, out, ind):
        lines = self.text.replace("--", "-").split("\n")
        if len(lines) == 1:
            out.append("%s<!-- %s -->" % (ind, lines[0]))
        else:
            out.append("%s<!-- %s" % (ind, lines[0]))
            out.extend("%s     %s" % (ind, l) for l in lines[1:-1])
            out.append("%s     %s -->" % (ind, lines[-1]))


class Ids:
    def __init__(self, client):
        self.client = client
        self.n = 0

    def __call__(self):
        self.n += 1
        return "%d:%d" % (self.client, self.n)


# ---------------------------------------------------------------------------
# View models
# ---------------------------------------------------------------------------

_PROP_EL = {
    "number": ("ViewModelPropertyNumber", "ViewModelInstanceNumber"),
    "string": ("ViewModelPropertyString", "ViewModelInstanceString"),
    "boolean": ("ViewModelPropertyBoolean", "ViewModelInstanceBoolean"),
    "trigger": ("ViewModelPropertyTrigger", "ViewModelInstanceTrigger"),
    "viewModel": ("ViewModelPropertyViewModel", "ViewModelInstanceViewModel"),
}
# A BindableProperty's element and propertyKey, by the property's kind.
_BINDABLE = {"number": ("BindablePropertyNumber", 636), "boolean": ("BindablePropertyBoolean", 634),
             "string": ("BindablePropertyString", 635), "trigger": ("BindablePropertyTrigger", 686)}


class Prop:
    def __init__(self, vm, name, kind, default, pid, ref=None, comment=None):
        self.vm, self.name, self.kind, self.default, self.id = vm, name, kind, default, pid
        self.ref, self.comment = ref, comment


class Instance:
    def __init__(self, vm, name, iid, values):
        self.vm, self.name, self.id, self.values = vm, name, iid, values


class ViewModel:
    """A view model: `prop` declares a property, `path` the absolute bind
    path of a property, through nested models."""

    def __init__(self, doc, name, comment=None):
        self.doc = doc
        self.name = name
        self.id = doc.ids()
        self.props = {}
        self.instances = []
        self.comment = comment

    def prop(self, name, kind, default=None, ref=None, comment=None):
        p = Prop(self, name, kind, default, self.doc.ids(), ref, comment)
        self.props[name] = p
        return p

    def instance(self, name, values=None):
        inst = Instance(self, name, self.doc.ids(), dict(values or {}))
        self.instances.append(inst)
        return inst

    def default(self):
        if not self.instances:
            self.instance("Default")
        return self.instances[0]

    def path(self, *names):
        ids, cur = [self.id], self
        for n in names:
            p = cur.props[n]
            ids.append(p.id)
            cur = p.ref
        return "-".join(ids)

    def el(self):
        e = El("ViewModel", {"defaultInstanceId": self.default().id, "name": self.name, "id": self.id})
        for p in self.props.values():
            if p.comment:
                e.add(Comment("%s: %s" % (p.name, p.comment)))
            a = {}
            if p.kind == "viewModel":
                a["viewModelReferenceId"] = p.ref.id
            a.update({"name": p.name, "id": p.id})
            e.add(El(_PROP_EL[p.kind][0], a))
        for inst in self.instances:
            ie = El("ViewModelInstance", {"exports": True, "name": inst.name, "id": inst.id})
            for p in self.props.values():
                v = inst.values.get(p.name, p.default)
                a = {}
                if p.kind == "trigger":
                    a["propertyValue"] = 0
                elif p.kind == "viewModel":
                    a["propertyValue"] = v.id if isinstance(v, Instance) else p.ref.default().id
                elif p.kind == "boolean":
                    a["propertyValue"] = bool(v)
                elif p.kind == "number":
                    a["propertyValue"] = v if v is not None else 0
                else:
                    a["propertyValue"] = v if v is not None else ""
                a["viewModelPropertyId"] = p.id
                ie.add(El(_PROP_EL[p.kind][1], a))
            e.add(ie)
        return e


# ---------------------------------------------------------------------------
# State machines: conditions, actions, listener inputs, layers
# ---------------------------------------------------------------------------


def bind(path, key, conv=None, **kw):
    a = {"sourcePathIds": path, "propertyKey": key, "converterId": conv}
    a.update(kw)
    return El("DataBindContext", a)


def when(path, kind, op="equal", value=None, converter=None):
    """A transition condition on a view model property: `kind` "boolean",
    "number", "string" or "trigger"; `op` equal, notEqual, lessThan,
    lessThanOrEqual, greaterThan, greaterThanOrEqual."""
    tag, key = _BINDABLE[kind]
    left = El("TransitionPropertyViewModelComparator", None,
              El(tag, None, El("DataBindContext", {"sourcePathIds": path, "propertyKey": key, "converterId": converter})))
    if kind == "boolean":
        right = El("TransitionValueBooleanComparator", {"value": bool(value)})
    elif kind == "number":
        right = El("TransitionValueNumberComparator", {"value": value})
    elif kind == "trigger":
        right = El("TransitionValueTriggerComparator")
    else:
        right = El("TransitionValueStringComparator", {"value": value})
    return El("TransitionViewModelCondition", {"opValue": None if op == "equal" else op}, left, right)


def changed(doc, path):
    """A condition true on the frame the number at `path` changes (a
    sequence counter as an event: the pins' pattern)."""
    return when(path, "trigger", converter=doc.conv_changed())


def set_value(path, kind, value):
    """A listener (or state) action writing a literal to a property."""
    if kind == "trigger":
        value = 1
    tag, key = _BINDABLE[kind]
    return El("ListenerViewModelChange", None,
              El(tag, {"propertyValue": value}, El("DataBindContext", {"sourcePathIds": path, "propertyKey": key,
                                                                        "direction": True})))


def fire(path):
    return set_value(path, "trigger", 1)


def write_from(doc, read_path, write_path, kind="number", converter=None):
    """An action writing `write_path` from `read_path` through `converter`
    (a toggle, a step, a copy)."""
    rid = doc.ids()
    tag, key = _BINDABLE[kind]
    return El("ListenerViewModelChange", {"fromViewModelProperty": True, "fromDataBindId": rid},
              El(tag, None,
                 El("DataBindContext", {"sourcePathIds": read_path, "propertyKey": key, "id": rid,
                                        "converterId": converter}),
                 El("DataBindContext", {"sourcePathIds": write_path, "propertyKey": key, "direction": True})))


def on_keys(*keys, phase=1, modifiers=None):
    return El("ListenerInputTypeKeyboard", {"listenerTypeValue": "keyboard"},
              *[El("KeyboardInput", {"keyType": k, "keyPhase": phase, "modifiers": modifiers}) for k in keys])


# W3C standard gamepad slots.
PAD = {"south": 0, "east": 1, "west": 2, "north": 3, "l1": 4, "r1": 5, "l2": 6, "r2": 7, "select": 8,
       "start": 9, "up": 12, "down": 13, "left": 14, "right": 15}


def on_pad(*buttons):
    return El("ListenerInputTypeGamepad", {"listenerTypeValue": "gamepad"},
              *[El("GamepadInput", {"kind": "button", "mapping": "standard", "inputIndex": PAD[b], "buttonPhase": 1})
                for b in buttons])


def on_pointer(kind):
    return El("ListenerInputType", {"listenerTypeValue": kind})


def on_semantic(*actions):
    return El("ListenerInputTypeSemantic", {"listenerTypeValue": "semanticAction"},
              *[El("SemanticInput", {"actionType": a}) for a in actions])


class State:
    def __init__(self, layer, sid, anim, name, actions):
        self.layer, self.id, self.anim, self.name = layer, sid, anim, name
        self.actions = list(actions)
        self.transitions = []

    def to(self, other, *conds, ms=0, exit_at=None):
        """A transition to `other` when every condition holds; `ms` its mix;
        `exit_at` (percent) makes it wait for the animation."""
        self.transitions.append((other, list(conds), ms, exit_at))
        return self


class Layer:
    def __init__(self, doc, name):
        self.doc = doc
        self.name = name
        self.id = doc.ids()
        self.states = []
        self.any = State(self, None, None, "Any", ())
        self.entry = None
        self.row = 0

    def state(self, name, anim=None, actions=()):
        s = State(self, self.doc.ids(), anim, name, actions)
        self.states.append(s)
        if self.entry is None:
            self.entry = s
        return s

    def _transition_el(self, other, conds, ms, exit_at):
        a = {"stateToId": other.id}
        if ms:
            a["duration"] = ms
        if exit_at is not None:
            a.update({"enableExitTime": True, "exitTimeIsPercetange": True, "exitTime": exit_at})
        return El("StateTransition", a, *conds)

    def el(self):
        e = El("StateMachineLayer", {"name": self.name, "id": self.id})
        n = len(self.states)
        anyst = El("AnyState", {"x": 160, "y": -160})
        for other, conds, ms, exit_at in self.any.transitions:
            anyst.add(self._transition_el(other, conds, ms, exit_at))
        e.add(anyst)
        e.add(El("ExitState", {"x": 160 + 200 * n, "y": -160}))
        e.add(El("EntryState", {"x": 0, "y": 0}, El("StateTransition", {"stateToId": self.entry.id})))
        for i, s in enumerate(self.states):
            st = El("AnimationState", {"x": 160 + 200 * i, "y": 120 * (i % 2), "animationId": s.anim,
                                       "stateName": s.name, "id": s.id})
            st.add(*s.actions)
            for other, conds, ms, exit_at in s.transitions:
                st.add(self._transition_el(other, conds, ms, exit_at))
            e.add(st)
        return e


class Machine:
    def __init__(self, doc, name):
        self.doc = doc
        self.name = name
        self.id = doc.ids()
        self.listeners = []
        self.layers = []

    def listen(self, name, target, *parts):
        """A listener on `target` (a node id): its inputs and actions."""
        self.listeners.append(El("StateMachineListener", {"targetId": target, "name": name, "id": self.doc.ids()},
                                 *parts))

    def layer(self, name):
        lay = Layer(self.doc, name)
        self.layers.append(lay)
        return lay

    def el(self):
        if not self.layers:
            self.layer("Idle").state("Idle")
        e = El("StateMachine", {"name": self.name, "id": self.id})
        e.add(*self.listeners)
        e.add(*[lay.el() for lay in self.layers])
        return e


# ---------------------------------------------------------------------------
# The document and its artboards
# ---------------------------------------------------------------------------


class Doc:
    """One Rive document: view models, converters, assets and artboards,
    written by `render` in that order."""

    def __init__(self, client):
        self.ids = Ids(client)
        self.models = []
        self._conv = {}
        self.roots = []      # converters, fonts, scripts: root elements
        self.boards = []
        self.sem_links = {}  # node id -> the SemanticData ids hidden while the node is keyed invisible

    def link_sem(self, node_id, sem_el):
        """Hides `sem_el` (a SemanticData) from the semantics tree whenever an
        animation keys the node `node_id` to opacity 0."""
        if sem_el.get("id") is None:
            sem_el.set("id", self.ids())
        self.sem_links.setdefault(node_id, []).append(sem_el.get("id"))
        return sem_el

    def view_model(self, name, comment=None):
        vm = ViewModel(self, name, comment)
        self.models.append(vm)
        return vm

    def root(self, el):
        self.roots.append(el)
        return el

    def converter(self, key, tag, attrs=None, *kids):
        """A converter, written once however many binds use it."""
        if key not in self._conv:
            cid = self.ids()
            a = dict(attrs or {})
            a.update({"name": key, "id": cid})
            self._conv[key] = cid
            self.roots.append(El(tag, a, *kids))
        return self._conv[key]

    def group(self, key, *convs):
        return self.converter(key, "DataConverterGroup", None,
                              *[El("DataConverterGroupItem", {"converterId": c}) for c in convs])

    def conv_whole(self):
        return self.converter("Whole", "DataConverterToString", {"decimals": 0, "round": True})

    def conv_decimals(self, n):
        return self.converter("Decimals %d" % n, "DataConverterToString", {"decimals": n, "round": True})

    def conv_not(self):
        return self.converter("Not", "DataConverterBooleanNegate")

    def conv_plus(self, n=1):
        return self.converter("Plus %g" % n, "DataConverterRangeMapper",
                              {"minInput": 0, "maxInput": 1, "minOutput": n, "maxOutput": 1 + n})

    def conv_changed(self):
        return self.converter("Changed", "DataConverterTrigger")

    def conv_range(self, lo, hi, out_lo, out_hi, clamp=True):
        return self.converter("Map %g..%g to %g..%g" % (lo, hi, out_lo, out_hi), "DataConverterRangeMapper",
                              {"minInput": lo, "maxInput": hi, "minOutput": out_lo, "maxOutput": out_hi,
                               "clampLower": clamp or None, "clampUpper": clamp or None})

    def formula(self, key, *tokens):
        return self.converter(key, "DataConverterFormula", None, *tokens)

    def conv_cycle(self, step, count):
        """(input + step) mod count: a selection moving and wrapping."""
        return self.formula("Cycle %+d of %d" % (step, count),
                            El("FormulaTokenParenthesisOpen"), El("FormulaTokenInput"),
                            f_op("+"), f_val(step % count), El("FormulaTokenParenthesisClose"),
                            f_op("%"), f_val(count))

    def conv_pad(self, n):
        return self.converter("Pad %d" % n, "DataConverterStringPad", {"length": n, "text": "0", "padType": 0})

    def board(self, name, w, h, **kw):
        b = Board(self, name, w, h, **kw)
        self.boards.append(b)
        return b

    def render(self, header=None):
        out = ['<Rive version="1" kind="fragment">']
        if header:
            Comment(header).write(out, "    ")
        for vm in self.models:
            if vm.comment:
                Comment(vm.comment).write(out, "    ")
            vm.el().write(out, "    ")
        for c in self.roots:
            c.write(out, "    ")
        x = 0
        for b in self.boards:
            b.x = x
            x += b.w + 200
            b.el().write(out, "    ")
            if b.component:
                El("ComponentAsset", {"artboardId": b.id, "name": b.name}).write(out, "    ")
        out.append("</Rive>")
        return "\n".join(out) + "\n"


# token helpers for DataConverterFormula
def f_in():
    return El("FormulaTokenInput")


def f_val(v=None, path=None):
    if path:
        return El("FormulaTokenValue", None, El("DataBindContext", {"sourcePathIds": path, "propertyKey": 777}))
    return El("FormulaTokenValue", {"operationValue": v})


def f_op(kind):
    return El("FormulaTokenOperation", {"operationType": {"+": 0, "-": 1, "*": 2, "/": 3, "%": 4}[kind]})


def f_fn(kind):
    return El("FormulaTokenFunction", {"functionType": {"min": 0, "max": 1, "round": 2, "ceil": 3, "floor": 4}[kind]})


def f_sep():
    return El("FormulaTokenArgumentSeparator")


def f_open():
    return El("FormulaTokenParenthesisOpen")


def f_close():
    return El("FormulaTokenParenthesisClose")


class Board:
    """An artboard: its children front to back (the first draws on top),
    a state machine `sm`, and its animations."""

    def __init__(self, doc, name, w, h, vm=None, component=False, style=None, clip=True, comment=None,
                 machine="Main"):
        self.doc, self.name, self.w, self.h = doc, name, w, h
        self.id = doc.ids()
        self.style_id = doc.ids()
        self.vm, self.component = vm, component
        self.style = dict(style or {})
        self.clip, self.comment = clip, comment
        self.kids = []
        self.sm = Machine(doc, machine)
        self.anims = []
        self.x = 0

    def add(self, *els):
        self.kids.extend(e for e in els if e is not None)
        return self

    def pose(self, name, keys):
        """A one-frame animation holding `keys`: [(object id, property name,
        "double" | "color" | "id" | "bool", value)]."""
        aid = self.doc.ids()
        a = El("LinearAnimation", {"loopValue": "loop", "duration": 1, "name": name, "id": aid})
        keys = list(keys)
        # a node's semantics leave the tree while it is keyed invisible (doc.sem_links)
        for obj, prop, kind, value in list(keys):
            if prop == "opacity":
                for sem in self.doc.sem_links.get(obj, ()):
                    keys.append((sem, "isHidden", "bool", value <= 0.001))
        for obj, prop, kind, value in keys:
            a.add(El("KeyedObject", {"objectId": obj},
                     El("KeyedProperty", {"property": prop}, El(_KF[kind], {"value": value}))))
        self.anims.append(a)
        return aid

    def timeline(self, name, frames, tracks, loop="oneShot", fps=None):
        """An animation of `frames` at 60 fps: tracks are (object id,
        property name, kind, [(frame, value, ease)]) where ease is None (a
        hold key), "linear", or a cubic (x1, y1, x2, y2)."""
        aid = self.doc.ids()
        a = El("LinearAnimation", {"loopValue": loop, "fps": fps, "duration": frames, "name": name, "id": aid})
        tracks = list(tracks)
        for obj, prop, kind, keys in list(tracks):
            if prop == "opacity":
                for sem in self.doc.sem_links.get(obj, ()):
                    hk, last = [], None
                    for frame, value, _ in keys:
                        h = value <= 0.001
                        if h != last:
                            hk.append((frame, h, None))
                            last = h
                    tracks.append((sem, "isHidden", "bool", hk))
        for obj, prop, kind, keys in tracks:
            kp = El("KeyedProperty", {"property": prop})
            for frame, value, ease in keys:
                k = El(_KF[kind], {"value": value, "frame": frame or None})
                if ease == "linear":
                    k.attrs.append(("interpolationType", "linear"))
                elif ease:
                    x1, y1, x2, y2 = EASES[ease] if isinstance(ease, str) else ease
                    k.attrs.append(("interpolationType", "cubic"))
                    k.add(El("CubicEaseInterpolator", {"x1": x1, "y1": y1, "x2": x2, "y2": y2}))
                kp.add(k)
            a.add(El("KeyedObject", {"objectId": obj}, kp))
        self.anims.append(a)
        return aid

    def el(self):
        a = {}
        if self.component:
            a["isComponent"] = True
        a["defaultStateMachineId"] = self.sm.id
        if self.vm is not None:
            a["viewModelId"] = self.vm.id
            a["viewModelInstanceId"] = self.vm.default().id
        a.update({"clip": self.clip, "x": self.x, "y": 0, "width": self.w, "height": self.h,
                  "styleId": self.style_id, "name": self.name, "id": self.id})
        e = El("Artboard", a)
        if self.comment:
            e.add(Comment(self.comment))
        e.add(El("LayoutComponentStyle", dict(_style(self.style), name="Artboard Style", id=self.style_id)))
        e.add(*self.kids)
        e.add(self.sm.el())
        e.add(*self.anims)
        return e


_KF = {"double": "KeyFrameDouble", "color": "KeyFrameColor", "id": "KeyFrameId", "bool": "KeyFrameBool",
       "uint": "KeyFrameUint"}
EASES = {
    "out": (0.16, 1.0, 0.3, 1.0),
    "inOut": (0.65, 0.0, 0.35, 1.0),
    "in": (0.7, 0.0, 0.84, 0.0),
    "back": (0.34, 1.56, 0.64, 1.0),
}


# ---------------------------------------------------------------------------
# Layout boxes
# ---------------------------------------------------------------------------

_UNITS = ("padding", "margin", "gap", "position", "minWidth", "maxWidth", "minHeight", "maxHeight", "border")


def _style(style):
    out = {}
    for k, v in style.items():
        if v is None:
            continue
        units = None
        if isinstance(v, tuple):
            v, units = v
        out[k] = v
        if k.startswith(_UNITS) and not k.endswith(("UnitsValue", "Value")) and k != "positionTypeValue":
            out[k + "UnitsValue"] = units or "points"
        elif k in ("width", "height") and units:
            out[k + "UnitsValue"] = units
    return out


def box(doc, name, w=None, h=None, dir="column", align="topLeft", inset=None, fill=None, bid=None, clip=None,
        **style):
    """A LayoutComponent with its style: `w`/`h` a number (fixed), "fill"
    or "hug"; `inset` a dict of edges that pins it absolutely."""
    bid = bid or doc.ids()
    sid = doc.ids()
    s = {}

    def scale(v):
        if v in ("fill", "hug"):
            return v, 0
        if v is None:
            return "hug", 0
        return "fixed", v

    ws, wv = scale(w)
    hs, hv = scale(h)
    s["layoutWidthScaleType"] = ws
    s["layoutHeightScaleType"] = hs
    s["flexDirectionValue"] = dir
    s["layoutAlignmentType"] = align
    if inset:
        s["positionTypeValue"] = "absolute"
        for edge, v in inset.items():
            s["position" + edge.capitalize()] = v
        if w == "fill" and "left" in inset and "right" in inset:
            s["layoutWidthScaleType"] = "fixed"
            s["widthUnitsValue"] = "auto"
        if h == "fill" and "top" in inset and "bottom" in inset:
            s["layoutHeightScaleType"] = "fixed"
            s["heightUnitsValue"] = "auto"
    s.update(style)
    a = {}
    if clip is not None:
        a["clip"] = clip
    a.update({"width": wv if isinstance(wv, (int, float)) else 0, "height": hv if isinstance(hv, (int, float)) else 0,
              "styleId": sid, "name": name, "id": bid})
    e = El("LayoutComponent", a)
    e.add(El("LayoutComponentStyle", dict(_style(s), name=name + " Style", id=sid)))
    if fill:
        e.add(El("Fill", {"name": "Fill"}, El("SolidColor", {"colorValue": fill, "name": "Color"})))
    return e


def semantics(role, label=None, bind_label=None, sid=None, value=None, value_conv=None, **flags):
    """A SemanticData: a role (rive docs semantics), its label, or
    `bind_label` a string property path for a label that follows data;
    `value` a property path for its value (through `value_conv` for a
    number)."""
    a = {"role": role, "label": label}
    a.update(flags)
    a["name"] = "Semantics"
    a["id"] = sid
    e = El("SemanticData", a)
    if bind_label:
        e.add(El("DataBindContext", {"sourcePathIds": bind_label, "propertyKey": 983}))
    if value:
        e.add(El("DataBindContext", {"sourcePathIds": value, "propertyKey": 984, "converterId": value_conv}))
    return e
