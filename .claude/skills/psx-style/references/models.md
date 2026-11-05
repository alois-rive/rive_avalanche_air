# Models: budgets, topology, characters, trees

A PSX model is a silhouette and a texture page. The silhouette carries
what the eye reads at 320 x 240; the texture carries everything else.

## Budgets

| Class | Triangles | Texture | Notes |
|---|---|---|---|
| Hero character (the player) | 300 to 600 | one 128 x 128 page | segmented, 10 to 15 rigid parts |
| Secondary character, animal | 150 to 350 | 64 x 64 to 128 x 128 | |
| Vehicle, board, sled | 100 to 400 | 64 x 128 | |
| Building (a chalet, a lift station) | 150 to 500 | one 128 x 128 page plus tiles | interiors are not modelled |
| Prop (a rail, a sign, a fence, a banner) | 12 to 150 | tiles or a 64 x 64 page | |
| Tree | 4 to 8 (2 to 4 crossed quads) | 64 x 128, 1-bit alpha | never modelled branches |
| Terrain, per 100 x 100 m around the play area | 1,500 to 4,000 | tiles | 1 to 2 m triangles near the line, coarser away |
| Whole visible frame | 8,000 to 20,000 | | about 4x a real PlayStation: the modern margin |

`psx_audit.py model <file> --max-tris N` holds a model to its class.

## Topology

- **Faceted where it shows**: hard surfaces and low-poly organics use flat
  faces (`shade flat`) or smooth normals per part (`shade smooth`), chosen
  per part: a head smooth, a box flat. Gouraud on smooth normals gives
  the era's soft, vertex-wide light.
- **No subdivision surfaces, no bevels** beyond one segment where an edge
  must catch light.
- **Every polygon earns its place in the silhouette.** A detail inside
  the outline is texture.
- **Quads are fine** (the PlayStation drew them); Hedra triangulates.

## Subdivide for the warp

The affine warp grows with a polygon's size on screen. Near the camera's
usual distance:

- the ground and walls the player passes close to: 1 to 2 m triangles;
- far terrain and backdrops: as coarse as the silhouette allows;
- a big flat sign the camera approaches: 2 x 2 to 4 x 4 quads.

The warp should be visible (it is the look) and never tear a texture
apart: if a texture smears across the screen, subdivide that surface.

## Characters: segmented, not skinned

The era's characters were rigid parts, one per limb segment, parented in a
hierarchy and rotated at the joints, the seams visible. It is cheaper, it
is authentic and it reads at 320 x 240.

- Parts: pelvis, chest, head, upper and lower arm, hand (x2), upper and
  lower leg, foot (x2): 13 to 15 parts, each a closed low-poly shape
  overlapping its neighbours a little at the joint.
- Each part a node under its joint node (`Node3D`), rotated by timelines
  or scripts; no `Skeleton3D` skinning needed (Hedra has it, 4 weights and
  255 bones, if a part must bend: a jacket's torso).
- One texture page for the whole character; its UV islands packed in it.
- Colour schemes are the page's palette swaps or `albedo` tints.

## Trees and foliage

- **Crossed quads**: two (or three, at 60 degrees) vertical quads sharing
  their centre line, `psx_cutout.wgsl`, a 64 x 128 texture. Vary each
  tree's yaw and scale (0.8 to 1.3) so the forest does not repeat.
- **Snow-laden tiers** are in the texture, not the mesh.
- A tree near the line can be a 6-sided cone stack (24 to 40 triangles)
  in `psx_surface` instead, if the camera passes within a few metres.

## UVs and texture pages

- One page per prop or character: `uv unwrap` or `uv smart-project`, then
  `uv pack`, so the page's 128 x 128 texels cover the model evenly.
- Tiled surfaces: `uv cube-project --size 1` (one UV unit a metre) and
  `uv_scale` on the material for the repeats.
- Texel density: about 16 to 32 texels a metre on what the camera passes
  close; it is meant to be coarse.

```sh
hedra model -p chalet.rmdl run - <<'EOS'
active Roof
mode edit
select all
uv smart-project --angle-limit 66 --margin 0.01
uv pack --margin 0.01
mode object
EOS
```

## Import

```
[params]
meshes/generate_lods=false
```

LODs are off (`hedra import <model> --set meshes/generate_lods=false`):
the fog hides the far clip, and a PSX model has no polygons to spare.
The Scene3D's `lodThreshold` 0 draws whole meshes.

## The blockout and the final

The asset pipeline's blockout (model-blockout) works unchanged; keep its
primitives at the final's vertex counts (`--vertices 6` to 8 for
cylinders, `--segments 8 --rings 6` for spheres), so the sheet already
shows the budget. The final (model-final) is built to the PSX concept, at
the class budget, faceted where the concept is; its fidelity sheet is
rendered through the PSX frame (SKILL.md, "Assets through the pipeline").
