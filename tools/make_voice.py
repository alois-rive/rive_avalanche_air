#!/usr/bin/env python3
"""Compile audio/lexicon.txt and the phoneme table below into
world/scripts/audio/voice_data.as: the announcer's formant voice
(docs/AUDIO.md, section 6).

Usage: python3 tools/make_voice.py [--check]
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "audio", "lexicon.txt")
OUT = os.path.join(ROOT, "world", "scripts", "audio", "voice_data.as")

# kinds
SIL, VOW, DIPH, GLIDE, NASAL, FRV, FRU, STV, STU, ASP, AFU, AFV = range(12)
KIND_NAMES = ["SIL", "VOWEL", "DIPH", "GLIDE", "NASAL", "FRIC_V", "FRIC_U", "STOP_V", "STOP_U",
              "ASP", "AFFR_U", "AFFR_V"]

# The phonemes: ARPAbet, a male voice's formants (Peterson and Barney,
# Klatt 1980) raised a little for a shout. Columns: kind, F1 F2 F3 (start),
# F1 F2 F3 (end, diphthongs), B1 B2 B3, AV (voicing), AF (frication), AH
# (aspiration), FF (frication centre, Hz), FQ (its Q), duration (ms).
P = {}


def ph(name, kind, f, fe=None, b=(70, 100, 150), av=0.0, af=0.0, ah=0.0, ff=0, fq=1.0, dur=80):
    P[name] = dict(kind=kind, f=f, fe=fe or f, b=b, av=av, af=af, ah=ah, ff=ff, fq=fq, dur=dur)


# vowels
ph("IY", VOW, (280, 2250, 3000), b=(60, 90, 150), av=1, dur=125)
ph("IH", VOW, (400, 1950, 2550), b=(70, 100, 150), av=1, dur=105)
ph("EH", VOW, (550, 1800, 2500), b=(70, 100, 150), av=1, dur=120)
ph("AE", VOW, (690, 1680, 2420), b=(80, 100, 150), av=1, dur=145)
ph("AA", VOW, (750, 1150, 2450), b=(80, 90, 150), av=1, dur=145)
ph("AO", VOW, (600, 880, 2450), b=(80, 90, 150), av=1, dur=145)
ph("UH", VOW, (450, 1050, 2250), b=(70, 90, 150), av=1, dur=100)
ph("UW", VOW, (320, 900, 2250), b=(60, 90, 150), av=1, dur=135)
ph("AH", VOW, (660, 1220, 2420), b=(80, 90, 150), av=1, dur=115)
ph("ER", VOW, (500, 1350, 1700), b=(70, 100, 120), av=1, dur=145)
ph("AX", VOW, (520, 1450, 2480), b=(80, 100, 150), av=1, dur=65)
# diphthongs
ph("EY", DIPH, (500, 1750, 2520), (340, 2200, 2950), b=(70, 100, 150), av=1, dur=175)
ph("AY", DIPH, (740, 1150, 2450), (380, 1950, 2800), b=(80, 100, 150), av=1, dur=195)
ph("OW", DIPH, (560, 1000, 2350), (380, 820, 2300), b=(80, 90, 150), av=1, dur=175)
ph("AW", DIPH, (740, 1250, 2450), (420, 900, 2300), b=(80, 90, 150), av=1, dur=195)
ph("OY", DIPH, (560, 880, 2420), (380, 1950, 2700), b=(80, 90, 150), av=1, dur=195)
# glides and liquids
ph("W", GLIDE, (290, 650, 2200), b=(70, 80, 150), av=0.75, dur=65)
ph("Y", GLIDE, (270, 2100, 3000), b=(60, 90, 150), av=0.75, dur=60)
ph("R", GLIDE, (330, 1100, 1450), b=(70, 90, 110), av=0.8, dur=65)
ph("L", GLIDE, (340, 1050, 2800), b=(80, 120, 160), av=0.75, dur=65)
# nasals
ph("M", NASAL, (270, 1150, 2200), b=(120, 160, 220), av=0.5, dur=70)
ph("N", NASAL, (270, 1550, 2600), b=(120, 160, 220), av=0.5, dur=65)
ph("NG", NASAL, (270, 2000, 2700), b=(120, 160, 220), av=0.5, dur=70)
# fricatives
# (the PA's band ends at 4 kHz: the hiss of S sits at 5 kHz, just over it)
ph("F", FRU, (340, 1100, 2100), af=0.32, ff=3800, fq=0.6, dur=95)
ph("TH", FRU, (320, 1300, 2550), af=0.25, ff=4500, fq=0.7, dur=85)
ph("S", FRU, (320, 1400, 2550), af=0.85, ff=5000, fq=2.0, dur=115)
ph("SH", FRU, (300, 1850, 2750), af=0.9, ff=2900, fq=1.8, dur=120)
ph("HH", ASP, (500, 1500, 2500), ah=0.7, dur=65)
ph("V", FRV, (230, 1100, 2100), av=0.45, af=0.2, ff=3800, fq=0.6, dur=65)
ph("DH", FRV, (270, 1300, 2550), av=0.45, af=0.15, ff=4500, fq=0.7, dur=45)
ph("Z", FRV, (250, 1400, 2550), av=0.4, af=0.5, ff=5000, fq=2.0, dur=80)
ph("ZH", FRV, (270, 1850, 2750), av=0.4, af=0.5, ff=2900, fq=1.8, dur=80)
# stops: a closure, a burst (af at ff), then aspiration (unvoiced) or voicing
ph("P", STU, (400, 1100, 2150), af=0.45, ah=0.5, ff=1200, fq=0.6, dur=85)
ph("T", STU, (400, 1650, 2600), af=0.8, ah=0.5, ff=4500, fq=1.2, dur=80)
ph("K", STU, (320, 1950, 2800), af=0.75, ah=0.5, ff=2400, fq=1.6, dur=85)
ph("B", STV, (220, 1100, 2150), av=0.15, af=0.3, ff=1200, fq=0.6, dur=65)
ph("D", STV, (220, 1650, 2600), av=0.15, af=0.4, ff=4200, fq=1.2, dur=55)
ph("G", STV, (250, 1950, 2800), av=0.15, af=0.4, ff=2400, fq=1.6, dur=65)
# affricates
ph("CH", AFU, (300, 1850, 2750), af=0.95, ff=3000, fq=1.8, dur=130)
ph("JH", AFV, (270, 1850, 2750), av=0.35, af=0.6, ff=3000, fq=1.8, dur=105)
ph("SIL", SIL, (500, 1500, 2500), dur=60)

ORDER = list(P.keys())


class LexError(Exception):
    pass


def parse(text):
    words = {}
    word_order = []
    lines = {}
    for n, raw in enumerate(text.splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        toks = line.split()
        if toks[0] == "word":
            name = toks[1]
            seq = []
            for t in toks[2:]:
                dur = 0
                if ":" in t:
                    t, d = t.split(":")
                    dur = int(d)
                stress = 0
                if t[-1].isdigit():
                    stress = int(t[-1])
                    t = t[:-1]
                if t not in P:
                    raise LexError("line %d: unknown phoneme %s in %s" % (n, t, name))
                seq.append((ORDER.index(t), stress, dur))
            words[name] = seq
            word_order.append(name)
        elif toks[0] == "line":
            lid = int(toks[1])
            rest = toks[2:]
            shout = False
            if rest and rest[0] == "!":
                shout = True
                rest = rest[1:]
            for w in rest:
                if w not in words:
                    raise LexError("line %d: unknown word %s" % (n, w))
            lines[lid] = (shout, rest)
        else:
            raise LexError("line %d: unknown keyword %s" % (n, toks[0]))
    return words, word_order, lines


def fmt(name, typ, values, per=12):
    rows = []
    for k in range(0, len(values), per):
        rows.append("    " + ", ".join(str(v) for v in values[k:k + per]) + ",")
    return "export const %s: StaticArray<%s> = [\n%s\n];\n" % (name, typ, "\n".join(rows))


def f32(v):
    return repr(float(v))


def emit(words, word_order, lines):
    out = ["// GENERATED by tools/make_voice.py from audio/lexicon.txt: do not edit.\n"
           "// The announcer's phonemes and words (docs/AUDIO.md, section 6), read by\n"
           "// formant.as. A word's phoneme: id | stress << 8 | duration ms << 10.\n"]
    for k, name in enumerate(KIND_NAMES):
        out.append("export const K_%s: i32 = %d;\n" % (name, k))
    out.append("export const PH_COUNT: i32 = %d;\n" % len(ORDER))
    for k, name in enumerate(ORDER):
        out.append("export const PH_%s: i32 = %d;\n" % (name, k))
    out.append(fmt("PH_KIND", "i32", [P[n]["kind"] for n in ORDER]))
    fs = []
    for n in ORDER:
        fs.extend(P[n]["f"])
        fs.extend(P[n]["fe"])
    out.append(fmt("PH_FORM", "f32", [f32(v) for v in fs], 6))
    bs = []
    for n in ORDER:
        bs.extend(P[n]["b"])
    out.append(fmt("PH_BW", "f32", [f32(v) for v in bs], 3))
    amps = []
    for n in ORDER:
        p = P[n]
        amps.extend([p["av"], p["af"], p["ah"], p["ff"], p["fq"]])
    out.append(fmt("PH_AMP", "f32", [f32(v) for v in amps], 5))
    out.append(fmt("PH_DUR", "f32", [f32(P[n]["dur"]) for n in ORDER]))
    starts, lens, seq = [], [], []
    for w in word_order:
        starts.append(len(seq))
        lens.append(len(words[w]))
        for (p, s, d) in words[w]:
            seq.append(p | (s << 8) | (d << 10))
    out.append("export const WORD_COUNT: i32 = %d;\n" % len(word_order))
    for k, w in enumerate(word_order):
        out.append("export const W_%s: i32 = %d;\n" % (w, k))
    out.append(fmt("WORD_START", "i32", starts))
    out.append(fmt("WORD_LEN", "i32", lens))
    out.append(fmt("WORD_PH", "i32", seq))
    n = max(lines) + 1
    ls, ll, lw, lsh = [], [], [], []
    for lid in range(n):
        shout, ws = lines.get(lid, (False, []))
        ls.append(len(lw))
        ll.append(len(ws))
        lsh.append(1 if shout else 0)
        lw.extend(word_order.index(w) for w in ws)
    out.append("export const LINE_COUNT: i32 = %d;\n" % n)
    out.append(fmt("LINE_START", "i32", ls))
    out.append(fmt("LINE_LEN", "i32", ll))
    out.append(fmt("LINE_WORDS", "i32", lw))
    out.append(fmt("LINE_SHOUT", "i32", lsh))
    return "".join(out)


def main():
    with open(SRC) as f:
        words, order, lines = parse(f.read())
    text = emit(words, order, lines)
    if "--check" in sys.argv:
        with open(OUT) as f:
            ok = f.read() == text
        print("voice_data.as is current" if ok else "voice_data.as is stale: run tools/make_voice.py")
        sys.exit(0 if ok else 1)
    with open(OUT, "w") as f:
        f.write(text)
    print("wrote %s: %d phonemes, %d words, %d lines" % (
        os.path.relpath(OUT, ROOT), len(ORDER), len(order), len(lines)))


if __name__ == "__main__":
    try:
        main()
    except LexError as e:
        print("lexicon.txt: %s" % e)
        sys.exit(1)
