#!/usr/bin/env python3
"""Runs psx-style's audits over the course's files (needs Pillow and NumPy):

    python3 tools/course/audit.py textures            # every world/textures/*.png at its CLUT
    python3 tools/course/audit.py frames <png>...      # psx_audit.py frame on each shot
"""
import glob
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
AUDIT = os.path.join(ROOT, ".claude", "skills", "psx-style", "scripts", "psx_audit.py")
COLORS = {"banners": 256, "arches": 256, "chrome_matcap": 32}


def main():
    what = sys.argv[1] if len(sys.argv) > 1 else "textures"
    ok = True
    if what == "textures":
        for p in sorted(glob.glob(os.path.join(ROOT, "world", "textures", "*.png"))):
            name = os.path.basename(p)[:-4]
            r = subprocess.run([sys.executable, AUDIT, "texture", p, "--max-colors", str(COLORS.get(name, 16))],
                               capture_output=True, text=True)
            last = r.stdout.strip().splitlines()[-1] if r.stdout.strip() else r.stderr
            print(last)
            ok = ok and r.returncode == 0
            if r.returncode:
                print(r.stdout)
    else:
        for p in sys.argv[2:]:
            r = subprocess.run([sys.executable, AUDIT, "frame", p, "--low-res", "320x240"], capture_output=True, text=True)
            print(r.stdout.strip())
            ok = ok and r.returncode == 0
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
