#!/usr/bin/env python3
"""The UI's screenshots and key/pad sessions on the full project (docs/RIVE.md;
the UI workstream's checks): build/shots/*.png, *.json, *.log.

    python3 tools/make_ui_shots.py              # every shot (about 40 s each: rive bakes per run)
    python3 tools/make_ui_shots.py title960 hud960
    python3 tools/make_ui_shots.py --list

The world writes its `out` pins on its first frame (to_source bindings), so a
shot sets them after a first --advance (a step, not a starting value). The
placeholder world's boolean pins ride visible nodes and read true until
GAMEPLAY writes them, so the shots set them false where it matters.
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = "build/shots"


def tag(c0, c1, c2, grade, line):
    return ((c0 * 4096 + c1 * 64 + c2) * 8) + grade * 2 + line


def d(**kv):
    out = []
    for k, v in kv.items():
        if isinstance(v, bool):
            v = "true" if v else "false"
        out.append("--data=data/%s=%s" % (k, v))
    return out


QUIET = d(comboActive=False, grinding=False, trickLive=False, trickSwitch=False, lineHigh=False)
TABLE = d(hs1Score=45000, hs1Tag=tag(1, 22, 1, 3, 1), hs2Score=40000, hs2Tag=tag(18, 1, 4, 3, 0),
          hs3Score=36000, hs3Tag=tag(26, 1, 16, 2, 1), hs4Score=31000, hs4Tag=tag(19, 11, 25, 2, 0),
          hs5Score=27000, hs5Tag=tag(13, 1, 24, 1, 1))
RES = d(resTricks=18450, resGrinds=9200, resComboBonus=12000, resLandings=4300, resTimeBonus=2000, resTotal=45950,
        resBestCombo=8400, resLongestAir=2.4, resPerfects=6, resCrashes=1, resStep=7)
HUD = d(phase=3, score=12450, time=83.45, comboActive=True, comboMult=3, comboSum=2450, grinding=True, balance=-0.4,
        trickLive=False, trickSwitch=False, trickSpin=720, trickDir=2, trickGrab1=1, trickPoints=1050, praise=2,
        progress=0.42, section=3)
F = ("data/startSeq,data/restartSeq,data/quitSeq,data/paused,data/scheme,data/ui*Seq,data/initials*,data/pad*,"
     "data/device,data/musicVolume,data/landingAssist,playing,ui/pauseSel,ui/ini*")


def png(name):
    return "--screenshot=%s/%s.png" % (OUT, name)


def dump(name):
    return ["--data-dump=%s/%s.json" % (OUT, name), "--data-dump-filter=" + F]


V960 = "--viewport=960x720"
V1280 = "--viewport=1280x720"
A2 = "--advance=2"

SHOTS = [
    ("title_960", [png("title_960"), V960, A2] + TABLE + ["--advance=30"]),
    ("title_1280", [png("title_1280"), V1280, A2] + TABLE + ["--advance=30"]),
    ("table_960", [png("table_960"), V960, A2] + TABLE + ["--advance=900"]),
    ("count_960", [png("count_960"), V960, A2] + QUIET + d(phase=1) + ["--advance=2"] + d(countdown=3)
     + ["--advance=20"]),
    ("go_1280", [png("go_1280"), V1280, A2] + QUIET + d(phase=1, countdown=1) + ["--advance=10"]
     + d(countdown=0, phase=3, captionLine=3, captionSeq=1) + ["--advance=14"]),
    ("hud_960", [png("hud_960"), V960, A2] + HUD + ["--advance=5"] + d(bankSeq=1) + ["--advance=24"]),
    ("hud_1280", [png("hud_1280"), V1280, A2] + HUD + ["--advance=5"] + d(bankSeq=1, perfectSeq=1)
     + ["--advance=3"]),
    ("results_960", [png("results_960"), V960, A2] + QUIET + RES + d(phase=6, resGrade=3, resRank=2)
     + ["--advance=100"]),
    ("results_1280", [png("results_1280"), V1280, A2] + QUIET + RES + d(phase=6, resGrade=1, resRank=0)
     + ["--advance=100"]),
    ("initials_960", [png("initials_960"), V960] + dump("initials_960") + [A2] + QUIET + TABLE
     + d(phase=7, resRank=3) + ["--advance=5", "--key=up", "--key=up", "--key=right", "--key=k", "--advance=12"]),
    ("pause_960", [png("pause_960"), V960] + dump("pause_960") + [A2] + QUIET + d(phase=3)
     + ["--advance=5", "--key=escape", "--advance=5", "--key=down", "--key=down", "--key=left", "--advance=10"]),
    ("pause_1280", [png("pause_1280"), V1280, A2] + QUIET + d(phase=6) + ["--advance=5", "--key=escape",
                                                                         "--advance=20"]),
    ("demo_960", [png("demo_960"), "--semantics=%s/demo_960.semantics.json" % OUT, V960, "--data=data/demo=true",
                  A2] + HUD + ["--advance=20"]),
    ("wipe_1280", [png("wipe_1280"), V1280, A2] + QUIET + d(phase=3) + ["--advance=2"] + d(praise=8, crashSeq=1)
     + ["--advance=72"]),
    ("semantics_hud", ["--semantics=%s/hud.semantics.json" % OUT, V960, A2] + HUD + ["--advance=30"]),
    ("keys_title", dump("keys_title") + ["--advance=5", "--key=right", "--advance=3", "--key=enter", "--advance=5"]),
    ("keys_run", dump("keys_run") + [A2] + d(phase=3) + ["--advance=3", "--key=r", "--advance=3", "--key=escape",
                                                         "--advance=5", "--key=down", "--advance=2", "--key=right",
                                                         "--advance=2", "--key=up", "--advance=2", "--key=enter",
                                                         "--advance=5"]),
    ("keys_results", dump("keys_results") + [A2] + d(phase=6) + ["--advance=3", "--key=enter", "--advance=3",
                                                                 "--key=escape", "--advance=3", "--key=up",
                                                                 "--advance=2", "--key=enter", "--advance=5"]),
    ("pad_title", [png("pad_title")] + dump("pad_title") + ["--advance=5", "--gamepad=axis@leftX:0.8", "--advance=3",
                                                            "--gamepad=axis@leftX:0", "--gamepad=axis@leftY:-0.5",
                                                            "--advance=3", "--gamepad=button@south:down",
                                                            "--gamepad=button@south:up", "--advance=5"]),
    ("pad_run", dump("pad_run") + [A2] + d(phase=3) + [
        "--advance=3", "--gamepad=button@forward:down", "--gamepad=button@forward:up", "--advance=3",
        "--gamepad=button@back:down", "--gamepad=button@back:up", "--advance=3",
        "--gamepad=button@dpadDown:down", "--gamepad=button@dpadDown:up", "--advance=2",
        "--gamepad=button@south:down", "--gamepad=button@south:up", "--advance=5"]),
]


def main():
    want = [a for a in sys.argv[1:] if not a.startswith("-")]
    if "--list" in sys.argv:
        print("\n".join(n for n, _ in SHOTS))
        return
    os.makedirs(os.path.join(ROOT, OUT), exist_ok=True)
    env = dict(os.environ)
    env.setdefault("RIVE_VERSION", "dev-8d3a7cc3")
    for name, args in SHOTS:
        if want and name not in want:
            continue
        log = os.path.join(ROOT, OUT, name + ".log")
        with open(log, "w") as f:
            r = subprocess.run(["rive", "."] + args, cwd=ROOT, env=env, stdout=f, stderr=subprocess.STDOUT)
        lines = [l.rstrip() for l in open(log) if ("error" in l or "wrote" in l) and "wgsl" not in l]
        print("== %s (exit %d) %s" % (name, r.returncode, " | ".join(lines[-3:])))


if __name__ == "__main__":
    main()
