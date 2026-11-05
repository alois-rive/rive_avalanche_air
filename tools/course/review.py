#!/usr/bin/env python3
"""Review renders of the course through the PSX frame: for each camera under
course.rscn's ReviewCams, a scene world/build/review/<name>.rscn (the frame
rig of psx-style, the course instanced under LowRes, the lens where the
camera is, the Daylight timeline copied with its targets inside the
instance) rendered at the camera's progress with `hedra render`, then
audited with psx_audit.py frame.

    python3 tools/course/review.py [name ...] [--size 960 720] [--out shots/review]

world/build/ is the Hedra project's own cache folder: git and the bake
leave it out. Needs `hedra` (and Pillow/NumPy for the audit, through
tools/course/audit.py run with a Python that has them).
"""
import math
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
WORLD = os.path.join(ROOT, "world")
sys.path.insert(0, HERE)

import course as C  # noqa: E402

# the progress each view stands at (for the light)
VIEW_S = {"Start": 2, "Warmup": 60, "Kickers": 470, "RailGarden": 650, "Split": 880, "LowLine": 1060,
          "HighLine": 1040, "HighDrop": 1145, "MegaLip": 1318, "MegaInrun": 1300, "MegaSide": 1340, "Finish": 1420, "Overview": 0}


def frame_rig(cam_xform, anim):
    return """<?xml version="1.0" encoding="UTF-8"?>
<!-- Written by tools/course/review.py: a review view of the course through the PSX frame. -->
<rscn format="2">
  <ext_resource id="1_present" type="Shader" path="res://psx/psx_present.wgsl"/>
  <ext_resource id="2_course" type="PackedScene" path="res://course/course.rscn"/>
  <sub_resource id="Env_frame" type="Environment">
    <property name="background_mode">1</property>
    <property name="background_color">Color(0, 0, 0, 1)</property>
    <property name="tonemap_mode">0</property>
  </sub_resource>
  <sub_resource id="Tex_low" type="ViewportTexture">
    <property name="viewport_path">NodePath("LowRes")</property>
  </sub_resource>
  <sub_resource id="Mat_present" type="ShaderMaterial">
    <property name="shader">ExtResource("1_present")</property>
    <property name="shader_parameter/screen">SubResource("Tex_low")</property>
    <property name="shader_parameter/low_res">Vector2(320, 240)</property>
  </sub_resource>
  <sub_resource id="Mesh_present" type="QuadMesh">
    <property name="material">SubResource("Mat_present")</property>
  </sub_resource>
  <sub_resource id="Mat_anchor" type="StandardMaterial3D">
    <property name="shading_mode">0</property>
    <property name="albedo_texture">SubResource("Tex_low")</property>
  </sub_resource>
  <sub_resource id="Mesh_anchor" type="QuadMesh">
    <property name="size">Vector2(0.001, 0.001)</property>
    <property name="material">SubResource("Mat_anchor")</property>
  </sub_resource>
  <node name="Review" type="Node3D"/>
  <node name="FrameEnvironment" type="WorldEnvironment" parent=".">
    <property name="environment">SubResource("Env_frame")</property>
  </node>
  <node name="Screen" type="Camera3D" parent=".">
    <property name="current">true</property>
  </node>
  <node name="Present" type="MeshInstance3D" parent="Screen">
    <property name="mesh">SubResource("Mesh_present")</property>
    <property name="position">Vector3(0, 0, -1)</property>
  </node>
  <node name="Anchor" type="MeshInstance3D" parent="Screen">
    <property name="mesh">SubResource("Mesh_anchor")</property>
    <property name="position">Vector3(0, 0, -2)</property>
  </node>
  <node name="LowRes" type="SubViewport" parent=".">
    <property name="size">Vector2i(320, 240)</property>
    <property name="render_target_update_mode">4</property>
    <property name="own_world_3d">true</property>
  </node>
  <node name="Course" parent="LowRes" instance="ExtResource(&quot;2_course&quot;)"/>
  <node name="Lens" type="Camera3D" parent="LowRes">
    <property name="transform">%s</property>
    <property name="fov">66</property>
    <property name="near">0.1</property>
    <property name="far">200</property>
    <property name="current">true</property>
  </node>
%s
</rscn>
""" % (cam_xform, anim)


def main():
    args = sys.argv[1:]
    size = ("960", "720")
    out = os.path.join(ROOT, "shots", "review")
    names = []
    stats = False
    i = 0
    while i < len(args):
        if args[i] == "--stats":
            stats = True
            i += 1
        elif args[i] == "--size":
            size = (args[i + 1], args[i + 2])
            i += 3
        elif args[i] == "--out":
            out = os.path.join(ROOT, args[i + 1])
            i += 2
        else:
            names.append(args[i])
            i += 1
    text = open(os.path.join(WORLD, "course", "course.rscn")).read()
    cams = re.findall(r'<node name="(\w+)" type="Camera3D" parent="ReviewCams">\s*<property name="transform">([^<]+)</property>',
                      text)
    anim = text[text.index("  <LinearAnimation"):text.index("</LinearAnimation>") + len("</LinearAnimation>")]
    anim = anim.replace('target="', 'target="LowRes/Course/')
    sky = re.search(r'<node name="Sky" type="MeshInstance3D"', text)
    os.makedirs(os.path.join(WORLD, "build", "review"), exist_ok=True)
    os.makedirs(out, exist_ok=True)
    for name, xf in cams:
        if names and name not in names:
            continue
        # the sky follows the lens (daylight.as does it at run time)
        nums = [float(v) for v in xf[len("Transform3D("):-1].split(",")]
        eye = nums[9:12]
        scene = frame_rig(xf, anim)
        scene = scene.replace('<node name="Lens"', '<node name="Sky" parent="LowRes/Course">\n    <property name="position">Vector3(%g, %g, %g)</property>\n  </node>\n  <node name="Lens"' % tuple(eye))
        path = os.path.join(WORLD, "build", "review", name + ".rscn")
        with open(path, "w") as f:
            f.write(scene)
        frame = int(round(1000 * min(1.0, VIEW_S.get(name, 0) / C.COURSE_LENGTH)))
        png = os.path.join(out, name + ".png")
        r = subprocess.run(["hedra", "render", os.path.relpath(path, ROOT), "-o", os.path.relpath(png, ROOT), "--size", size[0],
                            size[1], "--msaa", "off", "--animation", "Daylight", "--frame", str(frame), "--text"],
                           cwd=ROOT, capture_output=True, text=True)
        print(name, "frame", frame, "->", os.path.relpath(png, ROOT), "" if r.returncode == 0 else r.stdout + r.stderr)
        if stats:
            r = subprocess.run(["hedra", "inspect", os.path.relpath(path, ROOT), "--stats", "--camera", "LowRes/Lens", "--size",
                                "320", "240", "--text"], cwd=ROOT, capture_output=True, text=True)
            line = next((ln for ln in r.stdout.splitlines() if ln.startswith("camera")), r.stdout[:300])
            print("   ", line.split(";")[0])


if __name__ == "__main__":
    main()
