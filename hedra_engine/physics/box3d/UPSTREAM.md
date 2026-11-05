# box3d: Box3D in AnimaScript, copied as it is

This directory is a copy of the `lib/` directory of
[box3d-as](https://github.com/luigi-rosso/box3d-as), Luigi Rosso's port to
AnimaScript of [Box3D](https://github.com/erincatto/box3d), Erin Catto's 3D
physics engine, at commit 45404474d588885de6c8c229b86a28110fd415e3
(2026-10-30). Its `LICENSE` (MIT) is box3d-as's, the same bytes.

- upstream: https://github.com/luigi-rosso/box3d-as
- commit: 45404474d588885de6c8c229b86a28110fd415e3
- copied: `lib/*.as` (58 files) and `LICENSE`, byte for byte
- licence: MIT, Copyright (c) 2026 Erin Catto, Copyright (c) 2026 Luigi
  Rosso (AnimaScript port)

**Nothing here is edited.** `SHA256SUMS` holds the SHA-256 of every copied
file, and `python3 tools/check_box3d.py` fails when a file differs from it,
when one is missing or when one is added (the tools suite and CI run it).
`--upstream <a box3d-as checkout>` also compares each file with that
checkout's `lib/` and `LICENSE`, and its commit with the one above. A fix
goes upstream first, then comes here with the next copy.

To move to another upstream commit:

```sh
git clone https://github.com/luigi-rosso/box3d-as "$TMPDIR/box3d-as"
git -C "$TMPDIR/box3d-as" checkout <commit>
python3 tools/check_box3d.py --sync "$TMPDIR/box3d-as"   # copies lib/ and LICENSE, writes SHA256SUMS and the commit here
python3 tools/check_box3d.py --upstream "$TMPDIR/box3d-as"
```

## The rules it is kept under

- It imports nothing but the rive std (`rive/...`) and its own files, by
  relative paths, as upstream wrote them. Nothing in Hedra imports it but
  the engine's physics layer (`engine/src/physics/`, outside this
  directory), and nothing imports it yet (`tools/check_layers.py`).
- The engine's own checks of its sources leave it out: its warnings, its
  style and its names are upstream's. It is still compiled wherever the
  library is vendored, since rive compiles every `.as` file of a project,
  so it needs a rive with parallel calls (`rive/parallel`), which the
  pinned rive has (`tools/pins.env`).
- It is vendored with the rest of the library into every Rive project
  `hedra build` writes (`hedra_engine/physics/box3d/`), with this note, its
  `LICENSE` and `SHA256SUMS`.

What box3d-as is, its API (Box3D's C names: `b3CreateWorld`,
`b3World_Step`, `b3Body_GetPosition`, ...), its threading and its parity
with native Box3D are described in its own README and `CONVENTIONS.md`,
which are not copied: see the upstream repository at the commit above.
