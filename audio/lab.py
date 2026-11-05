#!/usr/bin/env python3
"""The audio lab: a small Rive project in build/lab/ that runs the sound
(world/scripts/audio/ and game_state.as, copied) without the world, so the
Spu renders in seconds rather than a full bake.

    python3 audio/lab.py demo [seconds]   the scripted session (audio_demo.as)  -> build/lab/demo.wav
    python3 audio/lab.py bank             every sound alone, logged              -> build/lab/bank.wav, bank.log
    python3 audio/lab.py silent [seconds] the processor started, nothing played  -> build/lab/silent.wav

Then audio/analyze.py reads the wavs.
"""
import os
import shutil
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LAB = os.path.join(ROOT, "build", "lab")

LAB_AS = """import { Layout, Context } from "rive/host";
import { game } from "./scripts/game_state";
import { SoundCore } from "./scripts/audio/sound_core";
import { AudioBank, AudioDemo } from "./scripts/audio/audio_demo";

const MODE: i32 = %(mode)d;   // 0 the demo, 1 the bank, 2 silent

export class Lab extends Layout {
    core: SoundCore = new SoundCore();
    demo: AudioDemo = new AudioDemo();
    bank: AudioBank = new AudioBank();
    frame: i32 = 0;
    peak: f32 = 0;
    t: f64 = 0;
    lastState: i32 = -1;
    lastLine: i32 = -1;
    override init(context: Context): bool {
        this.bank.first = %(first)d;
        this.bank.last = %(last)d;
        if (MODE != 3) this.core.start(game);
        return true;
    }
    override advance(seconds: f64): bool {
        const dt = <f32>seconds;
        if (MODE == 0) this.demo.step(game, dt);
        else if (MODE == 1) this.bank.step(game, this.core, dt);
        if (MODE == 3) return true;
        this.core.update(game);
        this.frame++;
        this.t += seconds;
        const ms = this.core.meter.musicState;
        if (ms != this.lastState) {
            console.log("MUSIC " + ms.toString() + " " + this.t.toString() + " bar " + this.core.meter.bar.toString());
            this.lastState = ms;
        }
        const ln = this.core.meter.speaking;
        if (ln != this.lastLine) {
            console.log("LINE " + ln.toString() + " " + this.t.toString());
            this.lastLine = ln;
        }
        const sp = this.core.meter.speechPeak;
        if (sp > this.peak) this.peak = sp;
        if (this.frame %% 30 == 0 && this.peak > 0) {
            console.log("SPEECHPEAK " + this.peak.toString());
            this.peak = 0;
        }
        return true;
    }
}
"""

RIVE_YAML = """name: lab
main: Lab
scripting: wasm
logs:
  file: build/rive.log
  problems: build/problems.log
exclude:
  - build
"""


def sync(mode, first=0, last=1000):
    scripts = os.path.join(LAB, "scripts")
    if os.path.isdir(scripts):
        shutil.rmtree(scripts)
    os.makedirs(os.path.join(scripts, "audio"))
    src = os.path.join(ROOT, "world", "scripts", "audio")
    for f in os.listdir(src):
        if f.endswith(".as") and not f.endswith("_test.as"):
            shutil.copy(os.path.join(src, f), os.path.join(scripts, "audio", f))
    shutil.copy(os.path.join(ROOT, "world", "scripts", "game_state.as"), scripts)
    with open(os.path.join(LAB, "rive.yaml"), "w") as f:
        f.write(RIVE_YAML)
    with open(os.path.join(LAB, "lab.as"), "w") as f:
        f.write(LAB_AS % {"mode": mode, "first": first, "last": last})


def main():
    """lab.py demo [seconds] | bank [first last [seconds]] | silent [seconds]"""
    what = sys.argv[1] if len(sys.argv) > 1 else "demo"
    if what == "test":
        os.makedirs(LAB, exist_ok=True)
        sync(2)
        src = os.path.join(ROOT, "world", "scripts", "audio")
        for f in os.listdir(src):
            if f.endswith("_test.as"):
                shutil.copy(os.path.join(src, f), os.path.join(LAB, "scripts", "audio", f))
        env = dict(os.environ, RIVE_VERSION=os.environ.get("RIVE_VERSION", "dev-97a754c8"))
        p = subprocess.run(["rive", LAB, "--test"], env=env, capture_output=True, text=True)
        out = p.stdout + p.stderr
        with open(os.path.join(LAB, "test.log"), "w") as f:
            f.write(out)
        print("\n".join(l for l in out.splitlines() if "rive " not in l or "test" in l)[-6000:])
        sys.exit(p.returncode)
    mode = {"demo": 0, "bank": 1, "silent": 2, "none": 3}[what]
    first, last, secs = 0, 1000, None
    rest = sys.argv[2:]
    if what == "bank" and len(rest) >= 2:
        first, last = int(rest[0]), int(rest[1])
        rest = rest[2:]
    if rest:
        secs = rest[0]
    if secs is None:
        secs = {"demo": "74", "bank": "430", "silent": "74", "none": "74"}[what]
    os.makedirs(LAB, exist_ok=True)
    sync(mode, first, last)
    wav = os.path.join(LAB, what + ".wav")
    env = dict(os.environ, RIVE_VERSION=os.environ.get("RIVE_VERSION", "dev-97a754c8"))
    cmd = ["rive", LAB, "--render-audio=" + wav, "--advance=%ss" % secs]
    t0 = time.time()
    p = subprocess.run(cmd, env=env, capture_output=True, text=True)
    dt = time.time() - t0
    log = p.stdout + p.stderr
    with open(os.path.join(LAB, what + ".log"), "w") as f:
        f.write(log)
    errors = [l for l in log.splitlines() if " error " in l or "failed" in l.lower()]
    for l in errors[:30]:
        print(l)
    print("%s: %s in %.1f s wall (exit %d)" % (what, wav, dt, p.returncode))
    sys.exit(p.returncode)


if __name__ == "__main__":
    main()
