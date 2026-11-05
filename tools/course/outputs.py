"""What make_course.py writes: the data module, the terrain and dressing
models, the course scene (with its materials, the trees, the lines, the
rails' paths, the sky, the environment and the Daylight timeline) and the
course map."""
import math
import os
import sys

import course as C
import as_data
import terrain_mesh
from build import BLK, G
from meshes import num, rmdlcmd
from samples import Data
from trees import Forest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import make_props  # noqa: E402

SOURCE = "tools/course/make_course.py from tools/course/course.py"

# ---- the materials (LOOK.md, section 4) --------------------------------------
# name: (shader, texture, {parameters}); every surface and cut-out material
# takes the sun's parameters, which the Daylight timeline keys.
SURFACE = "psx_surface"
CUTOUT = "psx_cutout"
CHROME = "psx_chrome"
MATERIALS = {
    "groomed": (SURFACE, "snow_groomed", {"uv_scale": (1 / 3, 1 / 3)}),
    "powder": (SURFACE, "snow_powder", {"uv_scale": (0.25, 0.25)}),
    "packed": (SURFACE, "snow_packed", {"uv_scale": (1 / 3, 1 / 3)}),
    "rock": (SURFACE, "rock", {"uv_scale": (0.25, 0.25)}),
    "ice": (SURFACE, "ice", {"uv_scale": (0.125, 0.125)}),
    "far": (SURFACE, "snow_powder", {"uv_scale": (1.0, 1.0), "albedo": (0.9, 0.92, 1.0, 1.0)}),
    "pine_a": (CUTOUT, "pine_a", {}),
    "pine_b": (CUTOUT, "pine_b", {}),
    "pine_cone": (SURFACE, "pine_cone", {}),
    "building": (SURFACE, "building", {}),
    "lift": (SURFACE, "lift", {}),
    "rail": (CHROME, None, {}),
    "box": (SURFACE, "box", {}),
    "bark": (SURFACE, "bark", {}),
    "banner": (SURFACE, "banners", {}),
    "arch": (SURFACE, "arches", {"overbright": 1.3}),
    "neon": (SURFACE, "arches", {"emission": (0.45, 0.2, 0.35), "overbright": 1.6}),
    "accent": (SURFACE, None, {"albedo": (0.66, 0.97, 0.19, 1.0), "overbright": 1.2}),
    "fence": (CUTOUT, "fence", {}),
    "crowd": (CUTOUT, "crowd", {}),
}
MAT_COLORS = {
    "groomed": (0.92, 0.94, 1.0), "powder": (0.9, 0.92, 0.98), "packed": (0.85, 0.88, 0.95), "rock": (0.38, 0.34, 0.4),
    "ice": (0.6, 0.75, 0.9), "far": (0.85, 0.88, 0.95), "pine_cone": (0.16, 0.3, 0.22), "building": (0.6, 0.45, 0.3),
    "lift": (0.4, 0.4, 0.45), "rail": (0.97, 0.22, 0.56), "box": (0.97, 0.53, 0.09), "bark": (0.5, 0.35, 0.25),
    "banner": (0.9, 0.2, 0.5), "arch": (0.97, 0.22, 0.56), "neon": (0.97, 0.3, 0.7), "accent": (0.66, 0.97, 0.19),
    "fence": (0.97, 0.53, 0.09), "crowd": (0.5, 0.5, 0.6), "pine_a": (0.2, 0.35, 0.25), "pine_b": (0.2, 0.35, 0.25),
}


def color(c):
    return "Color(%s)" % ", ".join(num(v) for v in (list(c) + [1.0])[:4])


def vec3(v):
    return "Vector3(%s)" % ", ".join(num(x) for x in v)


def argb(c):
    return "FF" + "".join("%02X" % max(0, min(255, int(round(v * 255)))) for v in c[:3])


class Scene:
    def __init__(self):
        self.ext = []
        self.sub = []
        self.nodes = []
        self.anims = []

    def ext_resource(self, rid, kind, path):
        self.ext.append('  <ext_resource id="%s" type="%s" path="%s"/>' % (rid, kind, path))

    def sub_resource(self, rid, kind, props):
        self.sub.append('  <sub_resource id="%s" type="%s">' % (rid, kind))
        for k, v in props:
            self.sub.append('    <property name="%s">%s</property>' % (k, v))
        self.sub.append("  </sub_resource>")

    def node(self, name, kind=None, parent=".", props=(), instance=None, comment=None):
        if comment:
            self.nodes.append("  <!-- %s -->" % comment)
        attrs = 'name="%s"' % name
        if kind:
            attrs += ' type="%s"' % kind
        if parent is not None:
            attrs += ' parent="%s"' % parent
        if instance:
            attrs += ' instance="ExtResource(&quot;%s&quot;)"' % instance
        if not props:
            self.nodes.append("  <node %s/>" % attrs)
            return
        self.nodes.append("  <node %s>" % attrs)
        for k, v in props:
            self.nodes.append('    <property name="%s">%s</property>' % (k, v))
        self.nodes.append("  </node>")

    def text(self, header):
        out = ['<?xml version="1.0" encoding="UTF-8"?>'] + header + ['<rscn format="2">']
        out += self.ext + [""] + self.sub + [""] + self.nodes + [""] + self.anims
        out.append("</rscn>")
        return "\n".join(out) + "\n"


def basis_rows(x, y, z):
    return [x[0], y[0], z[0], x[1], y[1], z[1], x[2], y[2], z[2]]


def transform(x, y, z, o):
    return "Transform3D(%s)" % ", ".join(num(v) for v in basis_rows(x, y, z) + list(o))


def look_at(eye, target):
    fx, fy, fz = (target[0] - eye[0], target[1] - eye[1], target[2] - eye[2])
    n = math.sqrt(fx * fx + fy * fy + fz * fz)
    f = (fx / n, fy / n, fz / n)
    zax = (-f[0], -f[1], -f[2])
    up = (0.0, 1.0, 0.0)
    xax = (up[1] * zax[2] - up[2] * zax[1], up[2] * zax[0] - up[0] * zax[2], up[0] * zax[1] - up[1] * zax[0])
    n = math.sqrt(sum(v * v for v in xax))
    xax = tuple(v / n for v in xax)
    yax = (zax[1] * xax[2] - zax[2] * xax[1], zax[2] * xax[0] - zax[0] * xax[2], zax[0] * xax[1] - zax[1] * xax[0])
    return transform(xax, yax, zax, eye)


class Course:
    def __init__(self, main, high, mega, base, feats, grid):
        self.data = Data(main, high, mega, base, feats, grid)
        self.forest = Forest(self.data)
        self.props = make_props.Dressing(self.data, self.forest)
        self.props.place()
        self.forest.scatter()
        self.forest.make_obstacles()
        self.terrain = terrain_mesh.build(self.data)

    # ---- files -----------------------------------------------------------------
    def files(self):
        out = {}
        out["world/scripts/course_data.as"] = as_data.module(self.data, self.forest)
        mats = [(name, MAT_COLORS[name]) for name in sorted(MAT_COLORS)]
        out["world/course/terrain.rmdlcmd"] = rmdlcmd(self.terrain, mats, SOURCE)
        self.dressing = self.props.meshes()
        out["world/course/dressing.rmdlcmd"] = rmdlcmd(self.dressing, mats, SOURCE)
        out["world/course/course.rscn"] = self.scene()
        import course_map
        out["shots/course_map.png"] = course_map.png(self)
        return out

    def report(self):
        d = self.data
        out = []
        tris = sum(m.tris() for m in self.terrain)
        dtris = sum(m.tris() for m in self.dressing)
        out.append("terrain: %d objects, %d triangles; dressing %d objects, %d triangles" %
                   (len(self.terrain), tris, len(self.dressing), dtris))
        out.append("grid: %d rows, %d nodes, %d coarse blocks" % (d.grid.rows, sum(len(r) for r in d.grid.h), len(d.grid.coarse)))
        out.append("high line: %.1f deg, bow %.1f m" % (d.high.beta * 180 / math.pi, d.high.bow))
        out.append("trees %d, cone pines %d, obstacles %d" % (len(self.forest.trees), len(self.forest.cones), len(self.forest.obstacles)))
        for j in d.feats.jumps:
            out.append("%-4s %-6s s %6.1f lip %.1f m %4.1f deg  table/knuckle %5.1f m  landing %4.1f deg  air %.2f s  "
                       "impact(-3/0/+3) %s" % (j.id, j.kind, j.s, j.h, j.theta * 180 / math.pi, j.xk, j.alpha * 180 / math.pi,
                                              j.air, " ".join("%s" % (j.report[k][2] if j.report[k] else "-") for k in (-3.0, 0.0, 3.0))))
        ride = getattr(self, "ride", None)
        if ride:
            total = sum(ride.values())
            parts = []
            for sec in C.SECTIONS:
                t = ride[sec[0]]
                flag = "" if abs(t - sec[7]) <= 0.15 * sec[7] else "!"
                parts.append("%d: %.1f s (%.0f)%s" % (sec[0], t, sec[7], flag))
            out.append("point-mass ride, high line: %s; total %.1f s (85 to 95)" % ("; ".join(parts), total))
        return out

    # ---- the scene ---------------------------------------------------------------
    def scene(self):
        d = self.data
        sc = Scene()
        sc.ext_resource("1_surface", "Shader", "res://psx/psx_surface.wgsl")
        sc.ext_resource("2_cutout", "Shader", "res://psx/psx_cutout.wgsl")
        sc.ext_resource("3_chrome", "Shader", "res://psx/psx_chrome.wgsl")
        sc.ext_resource("4_sky", "Shader", "res://psx/psx_sky.wgsl")
        sc.ext_resource("5_terrain", "PackedScene", "res://course/terrain.rmdlcmd")
        sc.ext_resource("6_dressing", "PackedScene", "res://course/dressing.rmdlcmd")
        sc.ext_resource("7_daylight", "Script", "res://scripts/daylight.as")
        shader_id = {SURFACE: "1_surface", CUTOUT: "2_cutout", CHROME: "3_chrome"}
        textures = sorted({t for _s, t, _p in MATERIALS.values() if t} | {"chrome_matcap", "mountains"})
        for t in textures:
            sc.ext_resource("tex_" + t, "Texture2D", "res://textures/%s.png" % t)
        sun0 = d.sun[0]
        for name in sorted(MATERIALS):
            shader, tex, params = MATERIALS[name]
            props = [("shader", 'ExtResource("%s")' % shader_id[shader])]
            if shader == CHROME:
                props.append(("shader_parameter/matcap", 'ExtResource("tex_chrome_matcap")'))
                props.append(("shader_parameter/tint", "Color(0.97, 0.45, 0.75, 1)"))
                props.append(("shader_parameter/reflectivity", "0.85"))
            else:
                if tex:
                    props.append(("shader_parameter/albedo_texture", 'ExtResource("tex_%s")' % tex))
                for k, v in sorted(params.items()):
                    if k in ("albedo",):
                        props.append(("shader_parameter/" + k, color(v)))
                    elif k == "emission":
                        props.append(("shader_parameter/" + k, color(v)))
                    elif isinstance(v, tuple):
                        props.append(("shader_parameter/" + k, "Vector2(%s)" % ", ".join(num(x, 5) for x in v)))
                    else:
                        props.append(("shader_parameter/" + k, num(v)))
                props += self.sun_params(sun0)
            sc.sub_resource("Mat_" + name, "ShaderMaterial", props)
        # the sky
        sc.sub_resource("Mat_sky", "ShaderMaterial", [
            ("shader", 'ExtResource("4_sky")'),
            ("shader_parameter/zenith", color(sun0["zenith"])),
            ("shader_parameter/horizon", color(sun0["horizon"])),
            ("shader_parameter/below", color(sun0["horizon"])),
            ("shader_parameter/bands", "10"),
            ("shader_parameter/sun_direction", vec3(sun0["dir"])),
            ("shader_parameter/sun_color", color(sun0["sun"])),
            ("shader_parameter/sun_size", "3.0"),
            ("shader_parameter/horizon_texture", 'ExtResource("tex_mountains")'),
            ("shader_parameter/horizon_repeat", "3"),
            ("shader_parameter/horizon_band", "Vector2(-2, 7)"),
            ("shader_parameter/horizon_tint", color((0.86, 0.9, 1.0))),
        ])
        sc.sub_resource("Mesh_sky", "SphereMesh", [("radius", "420"), ("height", "840"), ("radial_segments", "24"),
                                                   ("rings", "12"), ("material", 'SubResource("Mat_sky")')])
        sc.sub_resource("Env_game", "Environment", [
            ("background_mode", "1"), ("background_color", color(sun0["horizon"])), ("tonemap_mode", "0"),
            ("fog_enabled", "true"), ("fog_mode", "1"), ("fog_light_color", color(sun0["horizon"])),
            ("fog_depth_begin", num(sun0["fog_begin"])), ("fog_depth_end", num(sun0["fog_end"])), ("fog_density", "1.0"),
            ("glow_enabled", "true"), ("glow_levels/1", "1.0"), ("glow_levels/2", "1.0"), ("glow_levels/3", "0.0"),
            ("glow_levels/5", "0.0"), ("glow_hdr_threshold", "1.0"), ("glow_intensity", "0.6"),
        ])
        sc.sub_resource("Mesh_key", "QuadMesh", [("size", "Vector2(0.01, 0.01)")])
        # trees: a QuadMesh a variant, its bottom at the origin
        for v in ("a", "b"):
            sc.sub_resource("Mesh_pine_" + v, "QuadMesh", [("center_offset", "Vector3(0, 0.5, 0)"),
                                                          ("material", 'SubResource("Mat_pine_%s")' % v)])
        chunks = self.tree_chunks()
        for (ck, v), inst in sorted(chunks.items()):
            buf = []
            for x, y, z, h, w, yaw in inst:
                for a in (yaw, yaw + math.pi / 2):
                    c, s = math.cos(a), math.sin(a)
                    buf += [w * c, 0, s, x, 0, h, 0, y - 0.3, -w * s, 0, c, z]
            sc.sub_resource("Trees_%02d_%s" % (ck, v), "MultiMesh", [
                ("transform_format", "1"), ("instance_count", str(len(inst) * 2)),
                ("mesh", 'SubResource("Mesh_pine_%s")' % v),
                ("buffer", "PackedFloat32Array(%s)" % ", ".join(num(b, 3) for b in buf))])
        # the lines and the rails as curves
        self.curve(sc, "Curve_line", [(s["x"], s["y"], s["z"]) for s in d.main_samples[::5]])
        self.curve(sc, "Curve_high", [(s["x"], s["y"], s["z"]) for s in d.high_samples[::5]])
        for rl in d.rails:
            self.curve(sc, "Curve_" + rl["id"], rl["pts"][::4] + ([rl["pts"][-1]] if (len(rl["pts"]) - 1) % 4 else []))
        # ---- nodes
        sc.node("Course", "Node3D", None, [("script", 'ExtResource("7_daylight")')])
        sc.node("Environment", "WorldEnvironment", ".", [("environment", 'SubResource("Env_game")')],
                comment="the game world's environment and sky (the sky follows the lens: scripts/daylight.as)")
        sc.node("Sky", "MeshInstance3D", ".", [("mesh", 'SubResource("Mesh_sky")'),
                                               ("material_override", 'SubResource("Mat_sky")')])
        sc.node("Terrain", None, ".", instance="5_terrain", comment="the terrain's tiles (terrain.rmdlcmd), each its material")
        for m in self.terrain:
            sc.node(m.name, None, "Terrain", [("material_override", 'SubResource("Mat_%s")' % m.material)])
        sc.node("Dressing", None, ".", instance="6_dressing", comment="props and the features' meshes (dressing.rmdlcmd)")
        for m in self.dressing:
            sc.node(m.name, None, "Dressing", [("material_override", 'SubResource("Mat_%s")' % m.material)])
        sc.node("Trees", "Node3D", ".", comment="crossed-quad pines, a MultiMesh a chunk and variant")
        for (ck, v) in sorted(chunks):
            sc.node("Pines_%02d_%s" % (ck, v), "MultiMeshInstance3D", "Trees",
                    [("multimesh", 'SubResource("Trees_%02d_%s")' % (ck, v))])
        sc.node("Line", "Path3D", ".", [("curve", 'SubResource("Curve_line")')], comment="the line (the low line through the split) and the high line")
        sc.node("HighLine", "Path3D", ".", [("curve", 'SubResource("Curve_high")')])
        sc.node("Rails", "Node3D", ".", comment="each rail's, box's and log's grind curve (its top)")
        for rl in d.rails:
            sc.node(rl["id"], "Path3D", "Rails", [("curve", 'SubResource("Curve_%s")' % rl["id"])])
        sc.node("Keys", "Node3D", ".", [("visible", "false")],
                comment="one hidden node a material: the Daylight timeline keys the materials through them")
        for name in sorted(MATERIALS):
            if MATERIALS[name][0] == CHROME:
                continue
            sc.node(name, "MeshInstance3D", "Keys", [("mesh", 'SubResource("Mesh_key")'),
                                                      ("material_override", 'SubResource("Mat_%s")' % name)])
        self.fx(sc)
        self.review_cams(sc)
        self.daylight(sc)
        self.confetti_anim(sc)
        header = ["<!-- Generated by %s: do not edit." % SOURCE,
                  "     Sunset Ridge (docs/COURSE.md): the terrain, the features, the rails, the dressing,",
                  "     the lines, the sky and the environment, and the Daylight timeline that",
                  "     scripts/daylight.as scrubs along the rider's progress. -->"]
        return sc.text(header)

    # ---- the course's effects (LOOK.md, section 6; scripts/fx_course.as) ------
    def fx(self, sc):
        d = self.data
        sc.ext_resource("8_fx", "Script", "res://scripts/fx_course.as")
        sc.ext_resource("9_sprite", "Shader", "res://psx/psx_sprite.wgsl")
        for t in ("fx_flake", "fx_confetti", "fx_flare"):
            sc.ext_resource("tex_" + t, "Texture2D", "res://textures/%s.png" % t)
        # the flare: flat discs (psx_cutout: nearest, 1-bit; unlit: a white
        # ambient and no sun), one shape of the sheet each
        for k in range(4):
            sc.sub_resource("Mat_flare%d" % k, "ShaderMaterial", [
                ("shader", 'ExtResource("2_cutout")'), ("shader_parameter/albedo_texture", 'ExtResource("tex_fx_flare")'),
                ("shader_parameter/albedo", "Color(1, 0.9, 0.8, 1)"),
                ("shader_parameter/uv_scale", "Vector2(0.25, 1)"), ("shader_parameter/uv_offset", "Vector2(%s, 0)" % num(k * 0.25)),
                ("shader_parameter/sun_color", "Color(0, 0, 0, 1)"), ("shader_parameter/sky_ambient", "Color(1, 1, 1, 1)"),
                ("shader_parameter/ground_ambient", "Color(1, 1, 1, 1)"), ("shader_parameter/overbright", "1.4"),
                ("shader_parameter/snap_resolution", "Vector2(0, 0)")])
            sc.sub_resource("Mesh_flare%d" % k, "QuadMesh", [("material", 'SubResource("Mat_flare%d")' % k)])
        sc.sub_resource("Ramp_age", "Gradient", [("offsets", "PackedFloat32Array(0, 1)"),
                                                  ("colors", "PackedColorArray(1, 1, 1, 1, 1, 1, 1, 0)")])
        sc.sub_resource("Mat_flake", "ShaderMaterial", [
            ("shader", 'ExtResource("9_sprite")'), ("shader_parameter/sprite_sheet", 'ExtResource("tex_fx_flake")'),
            ("shader_parameter/frames_x", "2"), ("shader_parameter/frames_y", "1")])
        sc.sub_resource("Mesh_flake", "QuadMesh", [("size", "Vector2(0.22, 0.22)"), ("material", 'SubResource("Mat_flake")')])
        sc.sub_resource("Mat_confetti", "ShaderMaterial", [
            ("shader", 'ExtResource("9_sprite")'), ("shader_parameter/sprite_sheet", 'ExtResource("tex_fx_confetti")'),
            ("shader_parameter/frames_x", "2"), ("shader_parameter/frames_y", "1")])
        sc.sub_resource("Mesh_confetti", "QuadMesh", [("size", "Vector2(0.3, 0.3)"), ("material", 'SubResource("Mat_confetti")')])
        sc.sub_resource("Ramp_confetti", "Gradient", [
            ("interpolation_mode", "1"), ("offsets", "PackedFloat32Array(0, 0.25, 0.5, 0.75)"),
            ("colors", "PackedColorArray(0.97, 0.22, 0.56, 1, 0.66, 0.97, 0.19, 1, 0.97, 0.53, 0.09, 1, 0.19, 0.85, 0.97, 1)")])
        sc.node("Fx", "Node3D", ".", [("script", 'ExtResource("8_fx")')],
                comment="the course's effects: dusk snow over the lens, the finish's confetti, the lens flare (scripts/fx_course.as)")
        sc.node("Snow", "CPUParticles3D", "Fx", [
            ("emitting", "false"), ("amount", "150"), ("lifetime", "7.0"), ("local_coords", "false"),
            ("mesh", 'SubResource("Mesh_flake")'), ("emission_shape", "3"), ("emission_box_extents", "Vector3(26, 2, 26)"),
            ("direction", "Vector3(0.3, -1, 0.2)"), ("spread", "20.0"), ("gravity", "Vector3(0, -0.6, 0)"),
            ("initial_velocity_min", "1.2"), ("initial_velocity_max", "2.2"), ("color_ramp", 'SubResource("Ramp_age")')])
        p, _t = self.finish_point()
        for k, side in enumerate((-1, 1)):
            w = p["width"] / 2 + 3.0
            dx, dz = p["t"][0], p["t"][2]
            n = math.hypot(dx, dz)
            rx, rz = -dz / n, dx / n
            pos = (p["x"] + rx * side * w, p["y"] + 1.0, p["z"] + rz * side * w)
            sc.node("Confetti%s" % "LR"[k], "CPUParticles3D", "Fx", [
                ("position", vec3(pos)), ("emitting", "false"), ("amount", "120"), ("lifetime", "3.0"), ("one_shot", "true"),
                ("explosiveness", "0.85"), ("local_coords", "false"), ("mesh", 'SubResource("Mesh_confetti")'),
                ("direction", vec3((-rx * side * 0.5, 1.0, -rz * side * 0.5))), ("spread", "25.0"),
                ("gravity", "Vector3(0, -5, 0)"), ("initial_velocity_min", "10.0"), ("initial_velocity_max", "15.0"),
                ("damping_min", "2.0"), ("damping_max", "4.0"),
                ("color_initial_ramp", 'SubResource("Ramp_confetti")'), ("color_ramp", 'SubResource("Ramp_age")')])
        for i in range(5):
            sc.node("Flare%d" % i, "MeshInstance3D", "Fx", [("mesh", 'SubResource("Mesh_flare%d")' % [0, 3, 1, 2, 1][i]),
                                                             ("scale", "Vector3(0.001, 0.001, 0.001)")])

    def finish_point(self):
        m = self.data.main_samples
        i = int(round(C.FINISH_S))
        return m[i], i

    def confetti_anim(self, sc):
        L = ['  <LinearAnimation name="Confetti" fps="60" duration="2" loopValue="oneShot">']
        for side in "LR":
            L.append('    <KeyedObject target="Fx/Confetti%s">' % side)
            L.append('      <KeyedProperty property="emitting">')
            L.append('        <KeyFrameBool frame="0" value="false"/>')
            L.append('        <KeyFrameBool frame="1" value="true"/>')
            L.append("      </KeyedProperty>")
            L.append("    </KeyedObject>")
        L.append("  </LinearAnimation>")
        sc.anims += L

    def sun_params(self, k):
        return [("shader_parameter/sun_direction", vec3(k["dir"])),
                ("shader_parameter/sun_color", color(self.sun_scaled(k["sun"]))),
                ("shader_parameter/sky_ambient", color(k["sky_amb"])),
                ("shader_parameter/ground_ambient", color(k["ground_amb"]))]

    @staticmethod
    def sun_scaled(c):
        return tuple(v * 0.8 for v in c)

    def curve(self, sc, rid, pts):
        vals = []
        for i, p in enumerate(pts):
            a = pts[max(0, i - 1)]
            b = pts[min(len(pts) - 1, i + 1)]
            k = 1.0 / 6.0 if 0 < i < len(pts) - 1 else 1.0 / 3.0
            tin = tuple(-(b[j] - a[j]) * k for j in range(3))
            tout = tuple((b[j] - a[j]) * k for j in range(3))
            if i == 0:
                tin = (0.0, 0.0, 0.0)
            if i == len(pts) - 1:
                tout = (0.0, 0.0, 0.0)
            vals += list(tin) + list(tout) + list(p)
        sc.sub_resource(rid, "Curve3D", [
            ("bake_interval", "0.5"),
            ("_data", '{"points": PackedVector3Array(%s), "tilts": PackedFloat32Array(%s)}' % (
                ", ".join(num(v, 3) for v in vals), ", ".join("0" for _ in pts))),
            ("point_count", str(len(pts)))])

    def tree_chunks(self):
        g = self.data.grid
        span = C.TILE_BLOCKS * BLK * 4
        chunks = {}
        for x, y, z, h, w, yaw, var in self.forest.trees:
            ck = int((g.Z0 - z) // span)
            chunks.setdefault((ck, "ab"[var]), []).append((x, y, z, h, w, yaw))
        return chunks

    def review_cams(self, sc):
        d = self.data
        sc.node("ReviewCams", "Node3D", ".", comment="cameras for hedra render and the review scenes (tools/course/review.py)")
        for name, eye, target in self.review_views():
            sc.node(name, "Camera3D", "ReviewCams", [("transform", look_at(eye, target)), ("fov", "66"), ("near", "0.1"),
                                                     ("far", "500")])

    def review_views(self):
        d = self.data
        out = []

        def on(line_samples, s, back, up, ahead, side=0.0, look_up=0.0):
            i = max(0, min(len(line_samples) - 1, int(round(s - line_samples[0]["own_s"]))))
            p = line_samples[i]
            j = max(0, min(len(line_samples) - 1, i + int(ahead)))
            q = line_samples[j]
            t = p["t"]
            eye = (p["x"] - t[0] * back + side, p["y"] + up, p["z"] - t[2] * back)
            g = d.ground(eye[0], eye[2])
            if g and eye[1] < g[0] + 1.5:
                eye = (eye[0], g[0] + 1.5, eye[2])
            return eye, (q["x"], q["y"] + 1.0 + look_up, q["z"])
        m = d.main_samples
        h = d.high_samples
        for name, s, back, up, ahead in (("Start", 2, 6, 2.6, 30), ("Warmup", 60, 6, 2.6, 30), ("Kickers", 470, 7, 3.0, 32),
                                         ("RailGarden", 650, 6, 2.8, 30), ("Split", 880, 7, 3.0, 35),
                                         ("LowLine", 1060, 6, 2.6, 30), ("MegaInrun", 1300, 7, 3.0, 40),
                                         ("Finish", 1420, 7, 3.0, 40)):
            e, t = on(m, s, back, up, ahead)
            out.append((name, e, t))
        e, t = on(h, 1040, 6, 2.8, 30)
        out.append(("HighLine", e, t))
        # the mega-jump from the ridge's side (the Cliff camera's place)
        j = d.mega.j
        ox, oz, fx, fz, rx, rz = d.feats.mega_frame
        eye = (ox + fx * 30 - rx * 45, j.y0 + 6, oz + fz * 30 - rz * 45)
        out.append(("MegaSide", eye, (ox + fx * 35, j.y0 - 8, oz + fz * 35)))
        # the whole course from above the start
        out.append(("Overview", (60.0, 60.0, 40.0), (0.0, -150.0, -500.0)))
        return out

    # ---- the sunset ---------------------------------------------------------------
    def daylight(self, sc):
        d = self.data
        fps = 1000
        keys = d.sun
        L = []
        w = L.append
        w('  <LinearAnimation name="Daylight" fps="%d" duration="%d" loopValue="oneShot">' % (fps, fps))

        def frame_of(s):
            return int(round(fps * min(1.0, s / C.COURSE_LENGTH)))

        def track(prop, kind, values):
            w('      <KeyedProperty property="%s">' % prop)
            for k, val in zip(keys, values):
                if kind == "c":
                    w('        <KeyFrameColor frame="%d" value="%s" interpolationType="linear"/>' % (frame_of(k["s"]), argb(val)))
                else:
                    w('        <KeyFrameDouble frame="%d" value="%s" interpolationType="linear"/>' % (frame_of(k["s"]), num(val)))
            w("      </KeyedProperty>")

        for name in sorted(MATERIALS):
            if MATERIALS[name][0] == CHROME:
                continue
            w('    <KeyedObject target="Keys/%s">' % name)
            pre = "material_override:shader_parameter/"
            for ax, i in (("x", 0), ("y", 1), ("z", 2)):
                track(pre + "sun_direction:" + ax, "d", [k["dir"][i] for k in keys])
            track(pre + "sun_color", "c", [self.sun_scaled(k["sun"]) for k in keys])
            track(pre + "sky_ambient", "c", [k["sky_amb"] for k in keys])
            track(pre + "ground_ambient", "c", [k["ground_amb"] for k in keys])
            w("    </KeyedObject>")
        w('    <KeyedObject target="Sky">')
        pre = "material_override:shader_parameter/"
        track(pre + "zenith", "c", [k["zenith"] for k in keys])
        track(pre + "horizon", "c", [k["horizon"] for k in keys])
        track(pre + "below", "c", [k["horizon"] for k in keys])
        track(pre + "sun_color", "c", [k["sun"] for k in keys])
        track(pre + "horizon_tint", "c", [tuple(min(1.0, v * 1.12) for v in k["horizon"]) for k in keys])
        for ax, i in (("x", 0), ("y", 1), ("z", 2)):
            track(pre + "sun_direction:" + ax, "d", [k["dir"][i] for k in keys])
        w("    </KeyedObject>")
        w('    <KeyedObject target="Environment">')
        track("environment:fog_light_color", "c", [k["horizon"] for k in keys])
        track("environment:background_color", "c", [k["horizon"] for k in keys])
        track("environment:fog_depth_begin", "d", [k["fog_begin"] for k in keys])
        track("environment:fog_depth_end", "d", [k["fog_end"] for k in keys])
        w("    </KeyedObject>")
        # the snow starts falling at dusk (LOOK.md, section 6: from s = 1,000)
        w('    <KeyedObject target="Fx/Snow">')
        w('      <KeyedProperty property="emitting">')
        w('        <KeyFrameBool frame="0" value="false"/>')
        w('        <KeyFrameBool frame="%d" value="true"/>' % frame_of(1000.0))
        w("      </KeyedProperty>")
        w("    </KeyedObject>")
        w("  </LinearAnimation>")
        sc.anims += L
