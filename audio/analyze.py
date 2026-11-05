#!/usr/bin/env python3
"""Checks a render of the Spu (docs/AUDIO.md, section 12) with NumPy alone.

    analyze.py stats WAV [t0 t1]       peaks, NaN, clicks, loudness (BS.1770), centroid
    analyze.py tempo WAV [t0 t1]       the tempo by onset autocorrelation
    analyze.py timeline WAV [step]     short-term loudness and centroid every `step` s
    analyze.py bank WAV LOG OUTDIR     cuts the review bank into wavs, one per item, with metrics

The wavs rive --render-audio writes are 32-bit float; the cut ones are
16-bit PCM for any player.
"""
import os
import struct
import sys

import numpy as np


def read_wav(path):
    with open(path, "rb") as f:
        data = f.read()
    if data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise ValueError("not a wav")
    pos = 12
    fmt = None
    pcm = None
    while pos + 8 <= len(data):
        cid = data[pos:pos + 4]
        size = struct.unpack("<I", data[pos + 4:pos + 8])[0]
        body = data[pos + 8:pos + 8 + size]
        if cid == b"fmt ":
            tag, ch, rate, _, _, bits = struct.unpack("<HHIIHH", body[:16])
            if tag == 0xFFFE:
                tag = struct.unpack("<H", body[24:26])[0]
            fmt = (tag, ch, rate, bits)
        elif cid == b"data":
            pcm = body
        pos += 8 + size + (size & 1)
    tag, ch, rate, bits = fmt
    if tag == 3 and bits == 32:
        x = np.frombuffer(pcm, dtype="<f4")
    elif tag == 1 and bits == 16:
        x = np.frombuffer(pcm, dtype="<i2").astype(np.float32) / 32768
    else:
        raise ValueError("format %d/%d" % (tag, bits))
    n = len(x) // ch
    return x[:n * ch].reshape(n, ch).astype(np.float64), rate


def write_wav16(path, x, rate):
    x = np.clip(x, -1, 1)
    pcm = (x * 32767).astype("<i2")
    ch = x.shape[1]
    raw = pcm.tobytes()
    with open(path, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", 36 + len(raw)) + b"WAVE")
        f.write(b"fmt " + struct.pack("<IHHIIHH", 16, 1, ch, rate, rate * ch * 2, ch * 2, 16))
        f.write(b"data" + struct.pack("<I", len(raw)) + raw)


def k_weight(x, rate):
    """BS.1770's K-weighting as a magnitude response applied by FFT."""
    n = x.shape[0]
    nfft = 1 << int(np.ceil(np.log2(max(n, 2))))
    f = np.fft.rfftfreq(nfft, 1.0 / rate)
    z = np.exp(-2j * np.pi * f / rate)

    def biquad(b, a):
        return (b[0] + b[1] * z + b[2] * z * z) / (a[0] + a[1] * z + a[2] * z * z)
    # the 48 kHz coefficients (the response is close enough at 44.1 kHz for a check)
    h = biquad([1.53512485958697, -2.69169618940638, 1.19839281085285], [1, -1.69065929318241, 0.73248077421585])
    h = h * biquad([1, -2, 1], [1, -1.99004745483398, 0.99007225036621])
    mag = np.abs(h)
    out = np.empty_like(x)
    for c in range(x.shape[1]):
        X = np.fft.rfft(x[:, c], nfft)
        out[:, c] = np.fft.irfft(X * mag, nfft)[:n]
    return out


def loudness(x, rate):
    """Integrated loudness (LUFS, gated), and the short-term (3 s) maximum."""
    y = k_weight(x, rate)
    p = (y ** 2).sum(axis=1)
    blk = int(0.4 * rate)
    hop = int(0.1 * rate)
    if len(p) < blk:
        return -99.0, -99.0
    cs = np.concatenate([[0], np.cumsum(p)])
    starts = np.arange(0, len(p) - blk + 1, hop)
    ms = (cs[starts + blk] - cs[starts]) / blk
    lk = -0.691 + 10 * np.log10(ms + 1e-12)
    g = ms[lk > -70]
    if len(g) == 0:
        return -99.0, -99.0
    rel = -0.691 + 10 * np.log10(g.mean()) - 10
    g2 = ms[(lk > -70) & (lk > rel)]
    integ = -0.691 + 10 * np.log10(g2.mean()) if len(g2) else -99.0
    blk3 = int(3 * rate)
    st = -99.0
    if len(p) >= blk3:
        s3 = np.arange(0, len(p) - blk3 + 1, hop)
        m3 = (cs[s3 + blk3] - cs[s3]) / blk3
        st = float(np.max(-0.691 + 10 * np.log10(m3 + 1e-12)))
    return float(integ), st


def centroid(x, rate):
    m = x.mean(axis=1)
    if len(m) < 1024:
        return 0.0
    n = 4096
    hop = 2048
    acc = np.zeros(n // 2 + 1)
    w = np.hanning(n)
    for s in range(0, len(m) - n, hop):
        acc += np.abs(np.fft.rfft(m[s:s + n] * w)) ** 2
    f = np.fft.rfftfreq(n, 1.0 / rate)
    if acc.sum() <= 0:
        return 0.0
    return float((f * acc).sum() / acc.sum())


def band_energy(x, rate, lo, hi):
    m = x.mean(axis=1)
    X = np.abs(np.fft.rfft(m)) ** 2
    f = np.fft.rfftfreq(len(m), 1.0 / rate)
    tot = X.sum() + 1e-20
    return float(X[(f >= lo) & (f < hi)].sum() / tot)


def clicks(x, thr=0.2):
    """Clicks: a sample-to-sample step over `thr` that also stands out 8 times
    from the steps around it (10 ms), so noise and bright sounds, whose steps
    are large everywhere, do not count; and the largest step."""
    if len(x) < 3:
        return 0, 0.0
    d = np.abs(np.diff(x, axis=0)).max(axis=1)
    w = 480
    local = np.sqrt(np.convolve(d * d, np.ones(w) / w, mode="same"))
    hits = (d > thr) & (d > 8 * local)
    return int(hits.sum()), float(d.max())


def stats(x, rate, label=""):
    nan = int(np.isnan(x).sum() + np.isinf(x).sum())
    xx = np.nan_to_num(x)
    peak = float(np.abs(xx).max()) if len(xx) else 0.0
    pdb = 20 * np.log10(peak + 1e-12)
    rms = float(np.sqrt((xx ** 2).mean())) if len(xx) else 0.0
    nclick, dmax = clicks(xx)
    integ, st = loudness(xx, rate)
    c = centroid(xx, rate)
    dc = float(np.abs(xx.mean(axis=0)).max()) if len(xx) else 0.0
    return dict(label=label, seconds=len(xx) / rate, peak_db=pdb, rms_db=20 * np.log10(rms + 1e-12),
                lufs=integ, st_max=st, nan=nan, clicks=nclick, max_step=dmax, centroid=c, dc=dc)


def fmt_stats(s):
    return ("%-28s %6.2fs peak %6.1f dBFS  rms %6.1f  LUFS %6.1f  st.max %6.1f  centroid %6.0f Hz  "
            "steps>0.2 %d (max %.3f)  NaN %d  dc %.4f" % (
                s["label"], s["seconds"], s["peak_db"], s["rms_db"], s["lufs"], s["st_max"], s["centroid"],
                s["clicks"], s["max_step"], s["nan"], s["dc"]))


def tempo(x, rate):
    """The tempo (BPM) from an onset envelope's autocorrelation."""
    m = x.mean(axis=1)
    n = 1024
    hop = 256
    w = np.hanning(n)
    frames = []
    for s in range(0, len(m) - n, hop):
        frames.append(np.abs(np.fft.rfft(m[s:s + n] * w)))
    S = np.array(frames)
    S = np.log1p(100 * S)
    flux = np.maximum(np.diff(S, axis=0), 0).sum(axis=1)
    flux = flux - np.convolve(flux, np.ones(16) / 16, mode="same")
    flux = np.maximum(flux, 0)
    fr = rate / hop
    ac = np.correlate(flux, flux, mode="full")[len(flux) - 1:]
    best = None
    for bpm in np.arange(80, 200, 0.25):
        lag = 60.0 / bpm * fr
        # the beat and its multiples
        score = 0
        for k in (1, 2, 4):
            L = lag * k
            i = int(L)
            if i + 1 >= len(ac):
                continue
            score += ac[i] + (ac[i + 1] - ac[i]) * (L - i)
        if best is None or score > best[1]:
            best = (bpm, score)
    return best[0]


def spectrogram_png(x, rate, path, fmax=11025, width=900, height=360, n=1024):
    """A spectrogram (linear frequency to fmax, 70 dB range) with the waveform under it."""
    from PIL import Image
    m = x.mean(axis=1)
    hop = max(1, (len(m) - n) // width)
    w = np.hanning(n)
    cols = []
    for k in range(width):
        s = k * hop
        seg = m[s:s + n]
        if len(seg) < n:
            seg = np.pad(seg, (0, n - len(seg)))
        cols.append(20 * np.log10(np.abs(np.fft.rfft(seg * w)) + 1e-9))
    S = np.array(cols).T
    f = np.fft.rfftfreq(n, 1.0 / rate)
    S = S[f <= fmax]
    top = S.max()
    img = np.clip((S - (top - 70)) / 70, 0, 1)
    img = img[::-1]
    rows = np.linspace(0, img.shape[0] - 1, height).astype(int)
    img = img[rows]
    wave_h = 80
    canvas = np.zeros((height + wave_h, width), dtype=np.uint8)
    canvas[:height] = (img * 255).astype(np.uint8)
    # the waveform's envelope
    for k in range(width):
        seg = m[k * hop:k * hop + hop]
        if len(seg):
            a = min(1.0, float(np.abs(seg).max()))
            h = int(a * (wave_h - 2) / 2)
            c = height + wave_h // 2
            canvas[c - h:c + h + 1, k] = 200
    Image.fromarray(canvas, "L").save(path)


def formants(x, rate, order=10, target=10000):
    """The formants of a vowel by LPC (autocorrelation, Levinson), at ~10 kHz."""
    m = x.mean(axis=1)
    # resample by FFT to `target`
    n = len(m)
    k = int(n * target / rate)
    X = np.fft.rfft(m)
    y = np.fft.irfft(X[:k // 2 + 1], k) * (k / n)
    y = np.append(y[0], y[1:] - 0.94 * y[:-1])     # pre-emphasis
    y = y * np.hamming(len(y))
    r = np.correlate(y, y, mode="full")[len(y) - 1:len(y) + order]
    a = np.zeros(order + 1)
    a[0] = 1
    e = r[0]
    for i in range(1, order + 1):
        acc = r[i] + np.dot(a[1:i], r[i - 1:0:-1])
        kk = -acc / e
        a[1:i + 1] = a[1:i + 1] + kk * a[i - 1::-1][:i]
        e *= 1 - kk * kk
    roots = np.roots(a)
    roots = roots[np.imag(roots) > 0]
    f = np.angle(roots) * target / (2 * np.pi)
    bw = -np.log(np.abs(roots)) * target / np.pi
    keep = sorted((ff, bb) for ff, bb in zip(f, bw) if ff > 150 and bb < 500)
    return keep


def cut(x, rate, t0, t1):
    a = max(0, int(t0 * rate))
    b = min(len(x), int(t1 * rate))
    return x[a:b]


def main():
    cmd = sys.argv[1]
    if cmd == "stats":
        x, rate = read_wav(sys.argv[2])
        if len(sys.argv) > 4:
            x = cut(x, rate, float(sys.argv[3]), float(sys.argv[4]))
        print(fmt_stats(stats(x, rate, os.path.basename(sys.argv[2]))))
    elif cmd == "tempo":
        if len(sys.argv) == 5 and not sys.argv[3].endswith(".wav"):
            x, rate = read_wav(sys.argv[2])
            x = cut(x, rate, float(sys.argv[3]), float(sys.argv[4]))
            print("tempo %.2f BPM" % tempo(x, rate))
        else:
            for p in sys.argv[2:]:
                x, rate = read_wav(p)
                print("%-30s tempo %.2f BPM" % (os.path.basename(p), tempo(x, rate)))
    elif cmd == "formants":
        x, rate = read_wav(sys.argv[2])
        t0, t1 = float(sys.argv[3]), float(sys.argv[4])
        step = float(sys.argv[5]) if len(sys.argv) > 5 else 0.04
        t = t0
        while t + 0.03 <= t1:
            seg = cut(x, rate, t, t + 0.03)
            e = 20 * np.log10(np.sqrt((seg ** 2).mean()) + 1e-9)
            fs = formants(seg, rate)
            print("%6.3f  %5.1f dB  %s" % (t, e, "  ".join("%5.0f(%3.0f)" % (f, b) for f, b in fs[:4])))
            t += step
    elif cmd == "spec":
        x, rate = read_wav(sys.argv[2])
        if len(sys.argv) > 5:
            x = cut(x, rate, float(sys.argv[4]), float(sys.argv[5]))
        fmax = float(sys.argv[6]) if len(sys.argv) > 6 else 11025
        spectrogram_png(x, rate, sys.argv[3], fmax=fmax)
    elif cmd == "timeline":
        x, rate = read_wav(sys.argv[2])
        step = float(sys.argv[3]) if len(sys.argv) > 3 else 2.0
        t = 0.0
        while t < len(x) / rate:
            seg = cut(x, rate, t, t + step)
            s = stats(seg, rate, "%6.1f-%6.1f" % (t, t + step))
            bar = "#" * max(0, int((s["rms_db"] + 50) / 1.5))
            print("%s  peak %6.1f  rms %6.1f  centroid %6.0f  %s" % (s["label"], s["peak_db"], s["rms_db"], s["centroid"], bar))
            t += step
    elif cmd == "bank":
        x, rate = read_wav(sys.argv[2])
        out = sys.argv[4]
        os.makedirs(out, exist_ok=True)
        names = []
        for line in open(sys.argv[3]):
            i = line.find("BANK ")
            if i < 0:
                continue
            parts = line[i:].split()
            if parts[1] == "end":
                continue
            names.append((parts[1], float(parts[2]), float(parts[3])))
        for name, t0, t1 in names:
            seg = cut(x, rate, t0, t1)
            s = stats(seg, rate, name)
            print(fmt_stats(s))
            write_wav16(os.path.join(out, name + ".wav"), seg, rate)
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
