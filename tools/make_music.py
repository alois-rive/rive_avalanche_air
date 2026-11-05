#!/usr/bin/env python3
"""Compile audio/song.txt ("Ice Breaker (170)", docs/AUDIO.md, section 5)
into world/scripts/audio/music_data.as: the patterns as flat i32 tables the
Spu's sequencer reads on the audio thread.

Usage: python3 tools/make_music.py [--check]
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "audio", "song.txt")
OUT = os.path.join(ROOT, "world", "scripts", "audio", "music_data.as")

DRUMS = "KSGHORC"          # kick, snare, ghost, closed hat, open hat, ride, crash
VEL = {".": 0, "o": 1, "x": 2, "X": 3}
NOTE = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}
BASS_MODES = {"none": 0, "sub": 1, "reese": 2, "both": 3}
FX = {".": 0, "C": 1, "I": 2, "B": 3}   # B: both
TRACKS = ("drums", "bass", "stab", "arp", "harm")


class SongError(Exception):
    pass


def note_number(tok):
    m = re.fullmatch(r"([A-G])([#b]?)(-?\d)", tok)
    if not m:
        raise SongError("bad note %r" % tok)
    n = NOTE[m.group(1)] + {"": 0, "#": 1, "b": -1}[m.group(2)]
    return 12 * (int(m.group(3)) + 1) + n


def bars_of_rows(rows, name):
    """Joins a pattern's rows (bars separated by |) into a list of steps."""
    line = " ".join(rows)
    bars = [b.split() if " " in b.strip() or len(b.strip()) <= 3 else list(b.strip())
            for b in line.split("|")]
    return bars


def parse(text):
    song = {"tempo": 170, "swing": 50, "chords": {}, "chord_order": [], "patterns": {},
            "harm": {}, "sections": []}
    lines = [l.split("#", 1)[0].rstrip() for l in text.splitlines()]
    i = 0

    def block():
        nonlocal i
        body = []
        i += 1
        while i < len(lines) and lines[i].strip() != "end":
            if lines[i].strip():
                body.append(lines[i].strip())
            i += 1
        if i >= len(lines):
            raise SongError("missing end")
        return body

    while i < len(lines):
        line = lines[i].strip()
        if not line:
            i += 1
            continue
        words = line.split()
        kw = words[0]
        if kw == "tempo":
            song["tempo"] = float(words[1])
        elif kw == "swing":
            song["swing"] = float(words[1])
        elif kw == "chord":
            notes = [note_number(t) for t in words[2:]]
            if len(notes) != 5:
                raise SongError("chord %s needs 5 notes" % words[1])
            song["chords"][words[1]] = notes
            song["chord_order"].append(words[1])
        elif kw == "harm":
            for c in words[2:]:
                if c not in song["chords"]:
                    raise SongError("harm %s: unknown chord %s" % (words[1], c))
            song["harm"][words[1]] = words[2:]
        elif kw == "drums":
            name = words[1]
            rows = block()
            nbars = None
            data = None
            for row in rows:
                inst, pat = row.split(None, 1)
                if inst not in DRUMS:
                    raise SongError("drums %s: unknown row %s" % (name, inst))
                bars = [b.strip() for b in pat.split("|")]
                for b in bars:
                    if len(b) != 16:
                        raise SongError("drums %s row %s: a bar of %d steps" % (name, inst, len(b)))
                if data is None:
                    nbars = len(bars)
                    data = [[0] * 16 for _ in range(nbars)]
                if len(bars) != nbars:
                    raise SongError("drums %s: rows of different lengths" % name)
                shift = 2 * DRUMS.index(inst)
                for bi, b in enumerate(bars):
                    for s, ch in enumerate(b):
                        data[bi][s] |= VEL[ch] << shift
            song["patterns"][name] = ("drums", data)
        elif kw in ("bass", "arp", "stab"):
            name = words[1]
            rows = block()
            line2 = " ".join(rows)
            bars_txt = [b.strip() for b in line2.split("|")]
            data = []
            for b in bars_txt:
                toks = b.split() if kw != "stab" else list(b.replace(" ", ""))
                if len(toks) != 16:
                    raise SongError("%s %s: a bar of %d steps" % (kw, name, len(toks)))
                bar = []
                for t in toks:
                    if kw == "bass":
                        if t == "-":
                            bar.append(0)
                        elif t == ".":
                            bar.append(-1)
                        elif t.startswith("~"):
                            bar.append(note_number(t[1:]) + 256)
                        else:
                            bar.append(note_number(t))
                    elif kw == "arp":
                        bar.append(0 if t == "." else int(t) + 1)
                    else:
                        bar.append(VEL[t])
                data.append(bar)
            song["patterns"][name] = (kw, data)
        elif kw == "section":
            name = words[1]
            opts = dict(zip(words[2::2], words[3::2]))
            sec = {"name": name, "bars": int(opts.get("bars", 8)),
                   "bass": BASS_MODES[opts.get("bass", "both")],
                   "pad": float(opts.get("pad", 0)), "loop": int(opts.get("loop", 0)),
                   "tracks": {}, "fx": "." * int(opts.get("bars", 8))}
            for row in block():
                parts = row.split()
                if parts[0] == "fx":
                    sec["fx"] = parts[1]
                elif parts[0] in TRACKS:
                    sec["tracks"][parts[0]] = parts[1:]
                else:
                    raise SongError("section %s: unknown row %s" % (name, parts[0]))
            song["sections"].append(sec)
        else:
            raise SongError("unknown keyword %s" % kw)
        i += 1
    return song


def compile_song(song):
    pat = []            # 16 i32 a bar
    pat_bar = {}        # (pattern, bar) -> offset

    def bar_offset(name, b):
        key = (name, b)
        if key not in pat_bar:
            pat_bar[key] = len(pat)
            pat.extend(song["patterns"][name][1][b])
        return pat_bar[key]

    chord_index = {c: k for k, c in enumerate(song["chord_order"])}
    sec_rows = []       # 6 i32 a bar: drums, bass, stab, arp offsets (-1 none), chord, fx
    secs = []
    for sec in song["sections"]:
        n = sec["bars"]
        if len(sec["fx"]) != n:
            raise SongError("section %s: fx has %d bars, wants %d" % (sec["name"], len(sec["fx"]), n))
        per_track = {}
        for tr in TRACKS:
            seq = sec["tracks"].get(tr, ["-"])
            bars = []
            for p in seq:
                if p == "-":
                    bars.append(None)
                    continue
                if tr == "harm":
                    if p not in song["harm"]:
                        raise SongError("section %s: unknown harm %s" % (sec["name"], p))
                    bars.extend(("chord", chord_index[c]) for c in song["harm"][p])
                    continue
                if p not in song["patterns"]:
                    raise SongError("section %s: unknown pattern %s" % (sec["name"], p))
                kind, data = song["patterns"][p]
                if kind != tr:
                    raise SongError("section %s: %s is a %s pattern, not %s" % (sec["name"], p, kind, tr))
                bars.extend((p, b) for b in range(len(data)))
            if not bars:
                bars = [None]
            full = [bars[k % len(bars)] for k in range(n)]
            if len(bars) > n:
                raise SongError("section %s: %s has %d bars, more than %d" % (sec["name"], tr, len(bars), n))
            per_track[tr] = full
        start = len(sec_rows) // 6
        for k in range(n):
            row = []
            for tr in ("drums", "bass", "stab", "arp"):
                v = per_track[tr][k]
                row.append(-1 if v is None else bar_offset(v[0], v[1]))
            h = per_track["harm"][k]
            row.append(0 if h is None else h[1])
            row.append(FX[sec["fx"][k]])
            sec_rows.extend(row)
        secs.append((sec, start))
    return pat, sec_rows, secs, chord_index


def fmt_array(name, typ, values, per_line=16):
    lines = []
    for k in range(0, len(values), per_line):
        lines.append("    " + ", ".join(str(v) for v in values[k:k + per_line]) + ",")
    return "export const %s: StaticArray<%s> = [\n%s\n];\n" % (name, typ, "\n".join(lines))


def emit(song, pat, sec_rows, secs):
    chords = []
    for c in song["chord_order"]:
        chords.extend(song["chords"][c])
    out = []
    out.append("// GENERATED by tools/make_music.py from audio/song.txt: do not edit.\n"
               "// \"Ice Breaker (170)\" (docs/AUDIO.md, section 5) as tables for the\n"
               "// sequencer (sequencer.as). Drum steps: 2 bits of velocity per\n"
               "// instrument (K S G H O R C from bit 0); bass steps: 0 hold, -1\n"
               "// release, a MIDI note (+256: glide); stab steps: velocity; arp steps:\n"
               "// 0 rest, else 1 + an index into the chord over two octaves. A section\n"
               "// bar: drums, bass, stab, arp (offsets into PAT, -1 none), chord, fx.\n")
    out.append("export const TEMPO: f32 = %s;\n" % float(song["tempo"]))
    out.append("export const SWING: f32 = %s;\n" % (song["swing"] / 100.0))
    out.append("export const DRUM_KICK: i32 = 0;\nexport const DRUM_SNARE: i32 = 1;\n"
               "export const DRUM_GHOST: i32 = 2;\nexport const DRUM_HAT: i32 = 3;\n"
               "export const DRUM_OPEN: i32 = 4;\nexport const DRUM_RIDE: i32 = 5;\n"
               "export const DRUM_CRASH: i32 = 6;\nexport const DRUM_COUNT: i32 = 7;\n")
    out.append("export const FX_CRASH: i32 = 1;\nexport const FX_IMPACT: i32 = 2;\n")
    out.append("export const CHORD_COUNT: i32 = %d;\n" % len(song["chord_order"]))
    for k, c in enumerate(song["chord_order"]):
        out.append("export const CHORD_%s: i32 = %d;\n" % (re.sub(r"\W", "_", c).upper(), k))
    out.append(fmt_array("CHORD_NOTES", "i32", chords, 5))
    out.append(fmt_array("PAT", "i32", pat, 16))
    out.append(fmt_array("SEC_ROWS", "i32", sec_rows, 6))
    out.append("export const SECTION_COUNT: i32 = %d;\n" % len(secs))
    for k, (sec, start) in enumerate(secs):
        out.append("export const SEC_%s: i32 = %d;\n" % (sec["name"].upper(), k))
    out.append(fmt_array("SEC_START", "i32", [s for _, s in secs], 16))
    out.append(fmt_array("SEC_BARS", "i32", [s["bars"] for s, _ in secs], 16))
    out.append(fmt_array("SEC_BASS", "i32", [s["bass"] for s, _ in secs], 16))
    out.append(fmt_array("SEC_LOOP", "i32", [s["loop"] for s, _ in secs], 16))
    out.append(fmt_array("SEC_PAD", "f32", [repr(s["pad"]) for s, _ in secs], 16))
    return "".join(out)


def main():
    with open(SRC) as f:
        song = parse(f.read())
    pat, sec_rows, secs, _ = compile_song(song)
    text = emit(song, pat, sec_rows, secs)
    if "--check" in sys.argv:
        with open(OUT) as f:
            if f.read() != text:
                print("music_data.as is stale: run tools/make_music.py")
                sys.exit(1)
        print("music_data.as is current")
        return
    with open(OUT, "w") as f:
        f.write(text)
    print("wrote %s: %d sections, %d pattern bars, %d chords" % (
        os.path.relpath(OUT, ROOT), len(secs), len(pat) // 16, len(song["chord_order"])))


if __name__ == "__main__":
    try:
        main()
    except SongError as e:
        print("song.txt: %s" % e)
        sys.exit(1)
