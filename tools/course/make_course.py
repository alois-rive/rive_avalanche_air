#!/usr/bin/env python3
"""The course generator (docs/COURSE.md, section 10): reads course.py and
writes

  world/course/course.rscn            the course scene (terrain tiles, features,
                                      rails' Path3Ds, dressing, sensors, the lines,
                                      the sky, the environment, the Daylight timeline)
  world/course/terrain.rmdlcmd        the terrain's tiles, one object a tile and material
  world/course/dressing.rmdlcmd       the props and the features' meshes, by region and material
  world/scripts/course_data.as        what course_api.as reads: the ground grid, the
                                      lines, the rails, the obstacles, the features,
                                      the fall zones, the sun's keys
  shots/course_map.png                the course from above, every feature marked

    python3 tools/course/make_course.py           # write
    python3 tools/course/make_course.py --check   # exit 1 when a file would change or a check fails

Standard library only. The same table gives the same bytes.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
sys.dont_write_bytecode = True

import course as C  # noqa: E402
import build  # noqa: E402
import outputs  # noqa: E402
import checks  # noqa: E402


def main():
    check = "--check" in sys.argv
    main_line, high, mega = build.build_lines()
    base = build.Base(main_line, high)
    feats = build.Features(main_line, high, mega, base)
    grid = build.Grid(main_line, high, base, feats)
    course = outputs.Course(main_line, high, mega, base, feats, grid)
    files = course.files()
    problems = checks.run(course)
    changed = []
    for rel, data in files.items():
        path = os.path.join(ROOT, rel)
        if isinstance(data, str):
            data = data.encode("utf-8")
        old = open(path, "rb").read() if os.path.exists(path) else None
        if old != data:
            changed.append(rel)
            if not check:
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with open(path, "wb") as f:
                    f.write(data)
    for rel in changed:
        print(("would change " if check else "wrote ") + rel)
    for line in course.report():
        print(line)
    for p in problems:
        print("PROBLEM: " + p)
    sys.exit(1 if (check and changed) or problems else 0)


if __name__ == "__main__":
    main()
