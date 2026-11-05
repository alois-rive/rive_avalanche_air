#!/usr/bin/env python3
"""Writes world/scripts/lib/poses_data.as: the segmented rider's poses
(docs/RIDER.md, section 12; LOOK.md, section 5) as a table of joint angles,
which lib/rider_view.as blends each frame by the rider's state.

The rig (tools/make_rider.py builds its parts on the same numbers): the
Body node is the board's place, its nose -Z, up +Y; a regular rider faces
+X (the toe edge), the left side towards the nose. Joints are Node3Ds
whose rotation (Euler YXZ, radians, as a Node3D's `rotation`) a pose sets;
the Hips also move (an offset from their rest place).

A pose is authored as the hips' offset and turn, the spine's and the
head's turns, and the hands: either free (the shoulder and elbow angles)
or a point to reach (a grab: the board's toe or heel edge), solved by a
two-bone IK here; the legs are always solved so that the boots stay on
the board at their stance. So a pose is changed by its numbers and
rebuilt:

    python3 tools/make_poses.py
"""
import math
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "world", "scripts", "lib", "poses_data.as")

# ---- the rig (shared with make_rider.py) -------------------------------------
HIPS_REST = (0.0, 0.86, 0.0)          # in the Body's frame
CHEST_AT = (0.0, 0.08, 0.0)           # from the Hips
NECK_AT = (0.0, 0.50, 0.0)            # from the Chest
SHOULDER_AT = {"L": (0.0, 0.44, -0.19), "R": (0.0, 0.44, 0.19)}   # from the Chest
UPPER_ARM = 0.27
LOWER_ARM = 0.25
HIP_AT = {"L": (0.0, -0.06, -0.11), "R": (0.0, -0.06, 0.11)}      # from the Hips
THIGH = 0.40
SHIN = 0.40
ANKLE_UP = 0.11                       # the ankle above the board's top
BOARD_TOP = 0.035
STANCE = 0.26                         # each foot from the board's middle
BOARD_HALF_WIDTH = 0.14

JOINTS = [
    # name, parent index, rest offset from the parent
    ("Hips", -1, HIPS_REST),
    ("Chest", 0, CHEST_AT),
    ("Neck", 1, NECK_AT),
    ("ShoulderL", 1, SHOULDER_AT["L"]),
    ("ElbowL", 3, (0.0, -UPPER_ARM, 0.0)),
    ("WristL", 4, (0.0, -LOWER_ARM, 0.0)),
    ("ShoulderR", 1, SHOULDER_AT["R"]),
    ("ElbowR", 6, (0.0, -UPPER_ARM, 0.0)),
    ("WristR", 7, (0.0, -LOWER_ARM, 0.0)),
    ("HipL", 0, HIP_AT["L"]),
    ("KneeL", 9, (0.0, -THIGH, 0.0)),
    ("AnkleL", 10, (0.0, -SHIN, 0.0)),
    ("HipR", 0, HIP_AT["R"]),
    ("KneeR", 12, (0.0, -THIGH, 0.0)),
    ("AnkleR", 13, (0.0, -SHIN, 0.0)),
]
NAMES = [j[0] for j in JOINTS]
J = {n: i for i, n in enumerate(NAMES)}


def joint_path(i):
    parts = []
    while i >= 0:
        parts.append(JOINTS[i][0])
        i = JOINTS[i][1]
    return "/".join(reversed(parts))


def mirror_of(name):
    if name.endswith("L"):
        return name[:-1] + "R"
    if name.endswith("R") and name not in ("Hips",):
        return name[:-1] + "L"
    return name


# ---- small maths -----------------------------------------------------------------

def rx(a):
    c, s = math.cos(a), math.sin(a)
    return [[1, 0, 0], [0, c, -s], [0, s, c]]


def ry(a):
    c, s = math.cos(a), math.sin(a)
    return [[c, 0, s], [0, 1, 0], [-s, 0, c]]


def rz(a):
    c, s = math.cos(a), math.sin(a)
    return [[c, -s, 0], [s, c, 0], [0, 0, 1]]


def mm(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(3)) for j in range(3)] for i in range(3)]


def mv(a, v):
    return [sum(a[i][k] * v[k] for k in range(3)) for i in range(3)]


def tr(a):
    return [[a[j][i] for j in range(3)] for i in range(3)]


def euler(e):
    """Godot's YXZ: R = Ry Rx Rz."""
    return mm(mm(ry(e[1]), rx(e[0])), rz(e[2]))


def to_euler(m):
    """The YXZ Euler angles of a rotation matrix (Godot's get_euler YXZ)."""
    sx = -m[1][2]
    sx = max(-1.0, min(1.0, sx))
    x = math.asin(sx)
    if abs(sx) < 0.9999:
        y = math.atan2(m[0][2], m[2][2])
        z = math.atan2(m[1][0], m[1][1])
    else:
        y = math.atan2(-m[2][0], m[0][0])
        z = 0.0
    return (x, y, z)


def add(a, b):
    return [a[0] + b[0], a[1] + b[1], a[2] + b[2]]


def sub(a, b):
    return [a[0] - b[0], a[1] - b[1], a[2] - b[2]]


def scale(a, k):
    return [a[0] * k, a[1] * k, a[2] * k]


def length(a):
    return math.sqrt(a[0] ** 2 + a[1] ** 2 + a[2] ** 2)


def norm(a):
    l = length(a)
    return [a[0] / l, a[1] / l, a[2] / l]


def cross(a, b):
    return [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]


def dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def aim(down_to, bend_hint):
    """The rotation turning a limb's rest direction (0, -1, 0) to `down_to`,
    its bend plane holding `bend_hint` (its local +X towards the hint)."""
    y = scale(norm(down_to), -1.0)          # local +Y is up the limb (from the tip)
    x = sub(bend_hint, scale(y, dot(bend_hint, y)))
    if length(x) < 1e-6:
        x = [1.0, 0.0, 0.0] if abs(y[0]) < 0.9 else [0.0, 0.0, 1.0]
        x = sub(x, scale(y, dot(x, y)))
    x = norm(x)
    z = cross(x, y)
    return [[x[0], y[0], z[0]], [x[1], y[1], z[1]], [x[2], y[2], z[2]]]


def two_bone(root_world, parent_rot, target, l1, l2, bend_hint):
    """IK: the upper and lower bones' local Euler angles (the upper's in the
    parent's frame, the lower's in the upper's) placing the tip at
    `target`, the joint bending towards `bend_hint`."""
    d = sub(target, root_world)
    dist = min(length(d), l1 + l2 - 1e-4)
    dist = max(dist, abs(l1 - l2) + 1e-4)
    dn = norm(d)
    # the angle at the root between the target line and the upper bone
    a = math.acos(max(-1.0, min(1.0, (l1 * l1 + dist * dist - l2 * l2) / (2 * l1 * dist))))
    # the joint's direction: the target line turned by a towards the hint
    side = sub(bend_hint, scale(dn, dot(bend_hint, dn)))
    side = norm(side)
    upper_dir = add(scale(dn, math.cos(a)), scale(side, math.sin(a)))
    joint = add(root_world, scale(upper_dir, l1))
    lower_dir = norm(sub(add(root_world, scale(dn, dist)), joint))
    upper_world = aim(upper_dir, bend_hint)
    upper_local = mm(tr(parent_rot), upper_world)
    lower_world = aim(lower_dir, bend_hint)
    lower_local = mm(tr(upper_world), lower_world)
    return to_euler(upper_local), to_euler(lower_local), upper_world, lower_world


# ---- the poses ---------------------------------------------------------------------
# Each: hips offset (x, y), hips/chest/neck turns (x, y, z radians), and
# each arm: ("free", shoulder euler, elbow euler) or ("reach", (x, y, z) on
# the board, bend hint). Degrees below, turned to radians.
D = math.radians
ARMS_DOWN = {"L": ("free", (D(8), 0, D(10)), (0, 0, D(20))), "R": ("free", (D(-8), 0, D(10)), (0, 0, D(20)))}
ARMS_OUT = {"L": ("free", (D(55), 0, D(15)), (0, 0, D(25))), "R": ("free", (D(-55), 0, D(15)), (0, 0, D(25)))}


def pose(hx=0.0, hy=0.0, hips=(0, 0, 0), chest=(0, 0, 0), neck=(0, 0, 0), arms=None, wrist=(0, 0, 0)):
    return {"hx": hx, "hy": hy, "hips": hips, "chest": chest, "neck": neck, "arms": arms or ARMS_DOWN, "wrist": wrist}


TOE_MID = (BOARD_HALF_WIDTH, BOARD_TOP + 0.02, 0.0)
HEEL_MID = (-BOARD_HALF_WIDTH, BOARD_TOP + 0.02, 0.0)
TOE_NOSE = (BOARD_HALF_WIDTH, BOARD_TOP + 0.02, -0.45)
HEEL_TAIL = (-BOARD_HALF_WIDTH, BOARD_TOP + 0.02, 0.42)

# the head turned to look down the nose (-Z): a turn about Y
LOOK = (0, D(70), 0)

POSES = [
    # 0 Stand: flexed, looking down the board
    ("Stand", pose(hy=-0.04, chest=(0, D(25), D(6)), neck=LOOK, arms=ARMS_OUT)),
    # 1 Heel carve: sat back over the heel edge
    ("CarveHeel", pose(hx=-0.12, hy=-0.16, chest=(0, D(25), D(-12)), neck=LOOK,
                       arms={"L": ("free", (D(60), 0, D(-25)), (0, 0, D(15))), "R": ("free", (D(-60), 0, D(-25)), (0, 0, D(15)))})),
    # 2 Toe carve: knees over the toe edge, chest forward
    ("CarveToe", pose(hx=0.10, hy=-0.14, chest=(0, D(20), D(28)), neck=LOOK,
                      arms={"L": ("free", (D(40), 0, D(40)), (0, 0, D(30))), "R": ("free", (D(-40), 0, D(40)), (0, 0, D(30)))})),
    # 3 Tuck: low, chest down, arms in front
    ("Tuck", pose(hx=0.04, hy=-0.30, chest=(0, D(40), D(45)), neck=(0, D(60), D(-25)),
                  arms={"L": ("free", (D(15), 0, D(5)), (0, 0, D(80))), "R": ("free", (D(-15), 0, D(5)), (0, 0, D(80)))})),
    # 4 Crouch: loading the ollie
    ("Crouch", pose(hy=-0.30, chest=(0, D(25), D(30)), neck=LOOK,
                    arms={"L": ("free", (D(25), 0, D(-20)), (0, 0, D(40))), "R": ("free", (D(-25), 0, D(-20)), (0, 0, D(40)))})),
    # 5 Air: neutral, arms out
    ("Air", pose(hy=-0.12, chest=(0, D(25), D(10)), neck=LOOK,
                 arms={"L": ("free", (D(70), 0, D(10)), (0, 0, D(20))), "R": ("free", (D(-70), 0, D(10)), (0, 0, D(20)))})),
    # 6 Indy: the rear hand on the toe edge between the feet
    ("Indy", pose(hy=-0.48, chest=(0, D(15), D(55)), neck=(0, D(60), D(-20)),
                  arms={"L": ("free", (D(75), 0, D(20)), (0, 0, D(20))), "R": ("reach", TOE_MID, (0, 1, 1))})),
    # 7 Melon: the front hand on the heel edge between the feet
    ("Melon", pose(hx=-0.06, hy=-0.48, chest=(D(-15), D(35), D(30)), neck=LOOK,
                   arms={"L": ("reach", HEEL_MID, (0, 1, -1)), "R": ("free", (D(-75), 0, D(20)), (0, 0, D(20)))})),
    # 8 Method: the front hand on the heel edge, the board pulled up behind (an arch)
    ("Method", pose(hx=-0.04, hy=-0.44, hips=(0, 0, D(-10)), chest=(D(-10), D(40), D(20)), neck=(0, D(70), D(15)),
                    arms={"L": ("reach", HEEL_TAIL, (0, 1, -1)), "R": ("free", (D(-100), 0, D(-30)), (0, 0, D(10)))})),
    # 9 Mute: the front hand on the toe edge
    ("Mute", pose(hy=-0.48, chest=(0, D(10), D(55)), neck=(0, D(60), D(-20)),
                  arms={"L": ("reach", TOE_MID, (0, 1, -1)), "R": ("free", (D(-70), 0, D(30)), (0, 0, D(25)))})),
    # 10 FlipTuck: knees in, balled up
    ("FlipTuck", pose(hy=-0.40, chest=(0, D(10), D(50)), neck=(0, D(30), D(30)),
                      arms={"L": ("reach", (0.22, 0.45, -0.12), (0, 1, 0)), "R": ("reach", (0.22, 0.45, 0.12), (0, 1, 0))})),
    # 11 GrindLeft: balancing, leaning to the nose side (balance -1)
    ("GrindLeft", pose(hy=-0.16, hips=(D(10), 0, 0), chest=(D(-20), D(30), D(10)), neck=LOOK,
                       arms={"L": ("free", (D(30), 0, D(10)), (0, 0, D(20))), "R": ("free", (D(-100), 0, D(10)), (0, 0, D(20)))})),
    # 12 GrindRight: leaning to the tail side (balance +1)
    ("GrindRight", pose(hy=-0.16, hips=(D(-10), 0, 0), chest=(D(20), D(20), D(10)), neck=LOOK,
                        arms={"L": ("free", (D(100), 0, D(10)), (0, 0, D(20))), "R": ("free", (D(-30), 0, D(10)), (0, 0, D(20)))})),
    # 13 Absorb: a landing taken in the knees
    ("Absorb", pose(hy=-0.40, chest=(0, D(25), D(35)), neck=LOOK,
                    arms={"L": ("free", (D(45), 0, D(35)), (0, 0, D(40))), "R": ("free", (D(-45), 0, D(35)), (0, 0, D(40)))})),
    # 14 Wobble: a sketchy landing, windmilling
    ("Wobble", pose(hx=-0.08, hy=-0.18, chest=(D(15), D(25), D(-15)), neck=(0, D(50), D(-10)),
                    arms={"L": ("free", (D(120), 0, D(-40)), (0, 0, D(10))), "R": ("free", (D(-40), 0, D(80)), (0, 0, D(30)))})),
    # 15 FlailA: arms everywhere
    ("FlailA", pose(hy=-0.10, chest=(D(20), D(-10), D(-30)), neck=(D(20), D(20), D(-30)),
                    arms={"L": ("free", (D(150), 0, D(30)), (0, 0, D(60))), "R": ("free", (D(-120), 0, D(-40)), (0, 0, D(20)))})),
    # 16 FlailB
    ("FlailB", pose(hy=-0.25, chest=(D(-25), D(40), D(35)), neck=(D(-20), D(-20), D(20)),
                    arms={"L": ("free", (D(60), 0, D(-110)), (0, 0, D(50))), "R": ("free", (D(-150), 0, D(60)), (0, 0, D(10)))})),
    # 17 Celebrate: a fist pump, the front arm up
    ("Celebrate", pose(hy=-0.02, chest=(0, D(60), D(-5)), neck=(0, D(60), D(-15)),
                       arms={"L": ("free", (D(20), 0, D(170)), (0, 0, D(-30))), "R": ("free", (D(-40), 0, D(-10)), (0, 0, D(80)))})),
]


def solve(p):
    """The joint angles (15 x 3) and the hips' offset (3) of a pose."""
    ang = [(0.0, 0.0, 0.0)] * len(JOINTS)
    ang[J["Hips"]] = p["hips"]
    ang[J["Chest"]] = p["chest"]
    ang[J["Neck"]] = p["neck"]
    hips_pos = [HIPS_REST[0] + p["hx"], HIPS_REST[1] + p["hy"], HIPS_REST[2]]
    hips_rot = euler(p["hips"])
    chest_rot = mm(hips_rot, euler(p["chest"]))
    chest_pos = add(hips_pos, mv(hips_rot, CHEST_AT))
    for side in ("L", "R"):
        arm = p["arms"][side]
        sh_pos = add(chest_pos, mv(chest_rot, SHOULDER_AT[side]))
        if arm[0] == "free":
            ang[J["Shoulder" + side]] = arm[1]
            ang[J["Elbow" + side]] = arm[2]
        else:
            target = list(arm[1])
            hint = list(arm[2])
            u, l, _, _ = two_bone(sh_pos, chest_rot, target, UPPER_ARM, LOWER_ARM + 0.06, hint)
            ang[J["Shoulder" + side]] = u
            ang[J["Elbow" + side]] = l
        ang[J["Wrist" + side]] = p["wrist"]
        # the legs: the ankle over the boot's place on the board, the knee towards the toes
        hip_pos = add(hips_pos, mv(hips_rot, HIP_AT[side]))
        foot = [0.0, BOARD_TOP + ANKLE_UP, -STANCE if side == "L" else STANCE]
        u, l, uw, lw = two_bone(hip_pos, hips_rot, foot, THIGH, SHIN, [1.0, 0.2, 0.0])
        ang[J["Hip" + side]] = u
        ang[J["Knee" + side]] = l
        # the ankle back to the board's frame (the boot flat on it)
        ankle_world = mm(lw, [[1, 0, 0], [0, 1, 0], [0, 0, 1]])
        ang[J["Ankle" + side]] = to_euler(tr(ankle_world))
    return ang, (p["hx"], p["hy"], 0.0)


def main():
    rows = []
    for name, p in POSES:
        ang, off = solve(p)
        rows.append((name, ang, off))
    out = ["// Generated by tools/make_poses.py: do not edit (docs/RIDER.md, section 12).",
           "// The segmented rider's joints (paths from the rider scene's Body node) and its",
           "// poses: per pose, each joint's rotation (Euler YXZ, radians) then the Hips'",
           "// offset from their rest place (x, y, z). lib/rider_view.as blends them.", ""]
    out.append(f"export const JOINT_COUNT: i32 = {len(JOINTS)};")
    out.append("export const JOINT_PATHS: StaticArray<string> = [")
    out.extend(f'    "{joint_path(i)}",' for i in range(len(JOINTS)))
    out.append("];")
    out.append("// each joint's mirror (riding switch: left and right swapped)")
    out.append("export const JOINT_MIRROR: StaticArray<i32> = [")
    out.append("    " + ", ".join(str(J[mirror_of(n)]) for n in NAMES) + ",")
    out.append("];")
    out.append(f"export const HIPS_REST_X: f32 = {HIPS_REST[0]};")
    out.append(f"export const HIPS_REST_Y: f32 = {HIPS_REST[1]};")
    out.append(f"export const HIPS_REST_Z: f32 = {HIPS_REST[2]};")
    out.append("")
    for i, (name, _, _) in enumerate(rows):
        const = "POSE_" + "".join("_" + c if c.isupper() else c.upper() for c in name).lstrip("_")
        out.append(f"export const {const}: i32 = {i};")
    out.append(f"export const POSE_COUNT: i32 = {len(rows)};")
    stride = len(JOINTS) * 3 + 3
    out.append(f"export const POSE_STRIDE: i32 = {stride};")
    out.append("export const POSES: StaticArray<f32> = [")
    for name, ang, off in rows:
        vals = [v for a in ang for v in a] + list(off)
        out.append(f"    // {name}")
        for k in range(0, len(vals), 9):
            out.append("    " + ", ".join(f"{v:.5f}" for v in vals[k:k + 9]) + ",")
    out.append("];")
    text = "\n".join(out) + "\n"
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    old = open(OUT).read() if os.path.exists(OUT) else None
    if old != text:
        with open(OUT, "w") as f:
            f.write(text)
        print("wrote " + os.path.relpath(OUT, ROOT))


if __name__ == "__main__":
    main()
