#!/usr/bin/env python3
"""Fetches the UI's two fonts into fonts/ (docs/RIVE.md, section 7; LOOK.md,
section 8), both under the SIL Open Font License, which allows embedding
them in the .riv:

- Press Start 2P (CodeMan38): the pixel font, an 8 px design set at 8 and
  16 px for numbers and labels;
- Saira Italic (Omnibus-Type), the variable font (wdth 50..125, wght
  100..900): the wide italic techno display face, set at width 125 and
  weight 900 for trick names, praise words, grades and titles.

The files are committed; this script is how they were obtained (Google
Fonts' repository, ofl/), for a refresh.

    python3 tools/make_ui_fonts.py
"""
import os
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASE = "https://raw.githubusercontent.com/google/fonts/main/ofl/"
FILES = [
    ("PressStart2P-Regular.ttf", "pressstart2p/PressStart2P-Regular.ttf"),
    ("OFL-PressStart2P.txt", "pressstart2p/OFL.txt"),
    ("Saira-Italic-VF.ttf", "saira/Saira-Italic%5Bwdth,wght%5D.ttf"),
    ("OFL-Saira.txt", "saira/OFL.txt"),
]


def main():
    out = os.path.join(ROOT, "fonts")
    os.makedirs(out, exist_ok=True)
    for dst, src in FILES:
        data = urllib.request.urlopen(BASE + src, timeout=60).read()
        with open(os.path.join(out, dst), "wb") as f:
            f.write(data)
        print("wrote fonts/%s (%d bytes)" % (dst, len(data)))


if __name__ == "__main__":
    main()
