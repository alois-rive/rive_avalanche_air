"""make_course.py's checks (COURSE.md, section 10): every kicker's landing
meets its flight, the coarse blocks lie on their planes (the collision is
the render), the respawn points are safe, and a point-mass ride of the
line gives the sections' times (a stand-in for the reference rider, whose
autopilot is the gameplay's: its times are reported, not failed)."""
import math

import course as C
from build import G
from samples import SURF_GROOMED, SURF_POWDER


def run(course):
    d = course.data
    problems = []
    for j in d.feats.jumps:
        r = j.report
        if r[0.0] is None:
            problems.append("%s: the design flight does not land" % j.id)
            continue
        if r[0.0][2] > 9.5:
            problems.append("%s: the design landing's impact is %.1f m/s (over 9.5)" % (j.id, r[0.0][2]))
        if r[3.0] is None or r[3.0][2] > 13.5:
            problems.append("%s: 3 m/s over the design speed lands at %s m/s of impact" % (j.id, r[3.0]))
        if j.alpha > 38.5 * math.pi / 180:
            problems.append("%s: its landing is steeper than 38 degrees" % j.id)
    for row in C.KICKERS:
        j = next(x for x in d.feats.jumps if x.id == row[0])
        if abs(j.air - row[8]) > 0.08:
            problems.append("%s: air %.2f s, the table asks %.2f s" % (j.id, j.air, row[8]))
    # coarse blocks: every node on its block's planes (to the centimetre)
    g = d.grid
    for br, bc in sorted(g.coarse)[::7]:
        r = br * C.BLOCK
        c = bc * C.BLOCK
        A = g.node(r, c)
        B = g.node(r, c + 4)
        Cc = g.node(r + 4, c + 4)
        D = g.node(r + 4, c)
        for i in range(5):
            for k in range(5):
                fi, fk = i / 4, k / 4
                v = A + (B - A) * fk + (Cc - B) * fi if fk >= fi else A + (D - A) * fi + (Cc - D) * fk
                if abs(g.node(r + i, c + k) - v) > 0.011:
                    problems.append("coarse block %d,%d: node %d,%d off its plane" % (br, bc, i, k))
    # respawn: every safe sample on snow, not in the air, on the ground
    for name, smp in (("Line", d.main_samples), ("HighLine", d.high_samples)):
        n_safe = sum(1 for s in smp if s["safe"])
        if n_safe < len(smp) * 0.5:
            problems.append("%s: only %d of %d samples are safe respawns" % (name, n_safe, len(smp)))
        gap = 0
        for s in smp:
            gap = 0 if s["safe"] else gap + 1
            if gap > 140:
                problems.append("%s: %d m without a safe respawn before s=%.0f" % (name, gap, s["s"]))
                break
            if s["safe"] and (s["air"] or s["surface"] not in (SURF_GROOMED, SURF_POWDER)):
                problems.append("%s: an unsafe sample marked safe at s=%.0f" % (name, s["s"]))
    course.ride = ride(d)
    return problems


def ride(d, high=True):
    """A point mass down the line at the section's target speeds (tucked
    below them, carving above): each section's time."""
    smp = list(d.main_samples)
    if high:
        hs = d.high_samples
        smp = d.main_samples[:int(C.SPLIT_S)] + hs + d.main_samples[int(C.MERGE_S) + 1:]
    times = {sec[0]: 0.0 for sec in C.SECTIONS}
    v = 0.5
    g = 9.81
    for i in range(len(smp) - 1):
        a = smp[i]
        b = smp[i + 1]
        if a["s"] >= C.COURSE_LENGTH:
            break
        sec = next(s for s in C.SECTIONS if a["s"] < s[3] or s is C.SECTIONS[-1])
        t = (a["s"] - sec[2]) / (sec[3] - sec[2])
        target = sec[5] + (sec[6] - sec[5]) * t if sec[0] != 7 else 24.0
        if sec[0] == 1:
            target = max(target, 10.0)
        dx = b["x"] - a["x"]
        dy = b["y"] - a["y"]
        dz = b["z"] - a["z"]
        dl = math.sqrt(dx * dx + dy * dy + dz * dz)
        if a["air"]:
            times[sec[0]] += dl / max(v, 1.0)
            continue
        sin_t = -dy / dl
        cos_t = math.sqrt(max(0.0, 1 - sin_t * sin_t))
        k = 0.0028 if v < target else 0.0055
        acc = g * sin_t - 0.035 * g * cos_t - k * v * v
        if v > target:
            acc -= 2.0
        if v > 25:
            acc -= k * v * v
        v2 = v * v + 2 * acc * dl
        nv = math.sqrt(max(0.25, v2))
        times[sec[0]] += dl / max(0.5, (v + nv) / 2)
        v = nv
    return times
