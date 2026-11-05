#!/usr/bin/env python3
"""Writes the review wavs (audio/review/) from the lab's renders: every
instrument, one-shot, board layer, announcer line and music state alone,
named, and the scripted session. Mono 16-bit at 22,050 Hz, the SPU's own
rate, to keep them small (the renders themselves are 48 kHz stereo float).

    python3 audio/lab.py bank && python3 audio/lab.py demo
    build/py audio/review.py            (Python with NumPy)
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import analyze  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LAB = os.path.join(ROOT, "build", "lab")
OUT = os.path.join(ROOT, "audio", "review")
RATE = 22050

INST = ["kick", "snare", "ghost_snare", "hat", "open_hat", "ride", "crash", "reese_and_sub", "stab", "pad", "arp",
        "riser", "impact"]
EV = {1: "ollie", 2: "land", 102: "land_sketchy", 21: "perfect_shing_and_PERFECT", 3: "crash_and_OUCH",
      4: "bail_and_BAIL", 8: "grab", 7: "spin_half", 19: "gate_whoosh", 5: "grind_start_rail", 6: "grind_end",
      20: "confetti_and_cheer", 13: "ui_move", 14: "ui_select", 15: "ui_back", 10: "count_beep_and_THREE",
      110: "count_go_and_GO", 16: "tally_ticks", 17: "tally_end_kaching", 18: "grade_stamp_and_S_RANK"}
BOARD = ["glide_5ms", "glide_15ms", "glide_27ms", "powder_15ms", "ice_15ms", "carve_15ms", "skid_15ms",
         "wind_tuck_27ms", "air_whoosh", "rail_grind", "box_grind", "log_slide", "rock_15ms"]
LINES = ["THREE", "TWO", "ONE", "GO", "READY", "NICE", "SICK", "RADICAL", "INSANE", "UNREAL", "PERFECT", "SKETCHY",
         "OUCH", "WIPEOUT", "BAIL", "HIGH_LINE", "LOW_LINE", "FINAL_JUMP", "AWESOME", "S_RANK", "A_RANK", "B_RANK",
         "C_RANK", "NEW_RECORD", "COMBO", "YEAH", "SWEET", "NASTY", "GNARLY", "BIG_AIR", "AVALANCHE_AIR"]
TRICKS = ["BACKSIDE_720_INDY", "SWITCH_FRONTSIDE_540", "BACKFLIP_MELON", "FRONTSIDE_BACKFLIP_1080_METHOD_TO_MUTE",
          "KINKED_50-50", "RAINBOW_LOG_SLIDE"]
MUSIC = ["title_filtered_intro", "countdown_riser", "warmup_A1", "kickers_A2", "rails_B", "split_A3",
         "mega_riser", "mega_air", "mega_drop", "finish", "results_breakdown", "split_paused_after_2s"]


def to_review(x, rate):
    m = x.mean(axis=1)
    n = int(len(m) * RATE / rate)
    X = np.fft.rfft(m)
    y = np.fft.irfft(X[:n // 2 + 1], n) * (n / len(m))
    return y.reshape(-1, 1)


def name_of(kind, arg):
    if kind == 0:
        return "instrument_%02d_%s" % (arg, INST[arg])
    if kind == 1:
        return "oneshot_%s" % EV.get(arg, str(arg))
    if kind == 4:
        return "board_%02d_%s" % (arg, BOARD[arg])
    if kind == 2:
        return "voice_%02d_%s" % (arg, LINES[arg])
    if kind == 3:
        return "voice_trick_%s" % TRICKS[arg]
    if kind == 5:
        return "music_%02d_%s" % (arg, MUSIC[arg])
    return "k%d_%d" % (kind, arg)


def main():
    os.makedirs(OUT, exist_ok=True)
    for f in os.listdir(OUT):
        if f.endswith(".wav"):
            os.remove(os.path.join(OUT, f))
    x, rate = analyze.read_wav(os.path.join(LAB, "bank.wav"))
    rows = []
    for line in open(os.path.join(LAB, "bank.log")):
        i = line.find("BANK ")
        if i < 0:
            continue
        p = line[i:].split()
        if p[1] == "end":
            continue
        kind, arg = (int(v) for v in p[1][1:].split("_"))
        rows.append((kind, arg, float(p[2]), float(p[3])))
    for kind, arg, t0, t1 in rows:
        seg = analyze.cut(x, rate, t0, t1)
        if kind == 5:
            seg = seg[:int(min(t1 - t0, 8.5) * rate)]
        # the tail under -50 dBFS goes (a quarter second kept)
        loud = np.nonzero(np.abs(seg).max(axis=1) > 0.00316)[0]
        if len(loud):
            seg = seg[:min(len(seg), loud[-1] + int(0.25 * rate))]
        s = analyze.stats(seg, rate, name_of(kind, arg))
        print(analyze.fmt_stats(s))
        analyze.write_wav16(os.path.join(OUT, name_of(kind, arg) + ".wav"), to_review(seg, rate), RATE)
    demo = os.path.join(LAB, "demo.wav")
    if os.path.exists(demo):
        d, r = analyze.read_wav(demo)
        print(analyze.fmt_stats(analyze.stats(d, r, "session")))
        analyze.write_wav16(os.path.join(OUT, "session_scripted_run.wav"), to_review(d, r), RATE)
    total = sum(os.path.getsize(os.path.join(OUT, f)) for f in os.listdir(OUT))
    print("%d files, %.1f MB in %s" % (len(os.listdir(OUT)), total / 1e6, os.path.relpath(OUT, ROOT)))


if __name__ == "__main__":
    main()
