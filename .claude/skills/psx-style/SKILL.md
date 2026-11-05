---
name: psx-style
description: Make a Hedra (Rive 3D) scene, model, texture, sprite or UI read instantly as a 1990s PlayStation (PS1, PSX) game while using the engine's modern features - the frame at 320 x 240 shown with hard pixels, 15-bit colour and the PlayStation's dither, vertex snapping (wobbly, jittering polygons), affine texture warping, nearest-sampled 64 to 128 px palettised textures, Gouraud vertex lighting, distance fog, low-poly models with segmented characters and crossed-quad trees, blob shadows, sphere-mapped chrome - with tested reference shaders (WGSL), a frame template, texture and audit scripts, and the overrides this look needs at each stage of the asset pipeline (asset-pipeline, image-generate, model-blockout, model-concept, model-final, raster-asset). Use whenever a project asks for a PS1, PSX, retro 3D, low-poly 90s, "looks like a 1998 console game" or lo-fi 3D look, whenever such a project's assets are briefed, generated, built or checked, and whenever a modern effect (reflections, glow, depth of field, particles, decals, fog volumes) is added to such a look.
---

# The PSX look, with modern means

A screenshot reads as "a PlayStation game" from a handful of restrictions,
not from nostalgia: a picture of 320 x 240 pixels, each one a hard block;
colours that band and dither; polygons that wobble and textures that swim;
small, pixelly textures; light that lives on the vertices; a fog wall a
hundred metres out. Keep those visible restrictions exactly, and spend the
modern engine only where it adds polish without breaking one of them:
reflections on ice, a glowing sign, a lens flare, a thousand snow sprites,
60 frames a second, a widescreen option, a stable depth buffer.

![The showcase: a snow slope at 320 x 240, pillarboxed, with fogged crossed-quad pines, a banded sky with a sun and a mountain strip, a sphere-mapped chrome ball over its blob shadow, sprite snow puffs, a Gouraud-lit box, the floor's texture swimming affinely](references/images/psx_showcase.png)

That picture is this skill's frame template, shaders and textures, drawn by
`hedra render` (hedra 0.1.0) and passed by `psx_audit.py frame`.

## The signature: keep these exactly

| Trait | What the PlayStation did | Here | Default |
|---|---|---|---|
| **Low resolution, hard pixels** | 320 x 240 framebuffer on a TV | the game drawn into a 320 x 240 `SubViewport`, shown by `psx_present.wgsl` with nearest texels, pillarboxed to 4:3 ("The frame") | 320 x 240; 426 x 240 only as a widescreen option |
| **15-bit colour, dithered** | 5 bits a channel; the GPU dithered shaded polygons with a 4 x 4 table | `psx_present.wgsl`: the PlayStation's own dither offsets, then truncation to 5 bits, in display space, on the low-resolution grid | `color_bits` 5, `dither_strength` 1 |
| **Vertex snapping (jitter)** | the GTE had no sub-pixel precision: vertices land on whole pixels | `snap_view()` in every PSX shader: project, round to `snap_resolution`, unproject, in view space | 320 x 240 (160 x 120 for a cruder wobble) |
| **Affine texture warp** | UVs interpolated in screen space, no perspective correction | `(uv * w, w)` carried in a varying and divided per pixel, faded to perspective-correct within `affine_near` metres of the lens | `affine_strength` 1, `affine_near` 1 m |
| **Nearest texels, no mipmaps** | no filtering at all | `filter_nearest` texture uniforms; textures imported `compress/mode=lossless`, `mipmaps/generate=false` | always |
| **Small palettised textures** | 1 MB of VRAM, 256 x 256 texture pages, 4- or 8-bit CLUTs | 64 x 64 to 128 x 128, 16 colours (256 for faces and signage) on the 15-bit grid: `psx_texture.py` | 64 to 128 px, 16 colours |
| **Gouraud vertex light** | light computed per vertex and interpolated (or flat per face) | `vertex()` works out one sun, a hemisphere ambient and the mesh's tint, interpolated; `light_bands` for stepped light; flat faces with `shade flat` | Gouraud, no per-pixel light |
| **Distance fog, short draw distance** | depth cueing to a fog colour hid the far clip | the Environment's depth fog (`fog_mode` 1), its colour the sky's horizon | begins 20 to 40 m, ends 80 to 150 m |
| **Low polygon counts** | about 3,000 to 5,000 triangles a frame on screen | budgets per asset class ([references/models.md](references/models.md)) | hero 300 to 800, a frame under 20,000 |
| **Segmented characters, crossed-quad trees, billboards** | rigid parts per limb; trees as two crossed textured quads | rigid parts parented to joints; `psx_cutout.wgsl` on crossed quads; `psx_sprite.wgsl` | always for trees and effects |
| **1-bit transparency** | texel colour 0 was transparent | `ALPHA_SCISSOR_THRESHOLD` (`psx_cutout`, `psx_sprite`); no soft alpha on surfaces; a translucent character is a screen door (`screen_door`) | cut at 0.5 |
| **Blob shadows** | a dark disc or polygon under the character | `psx_blob_shadow.wgsl` on a plane placed by script, multiplied over the ground | no real-time shadows |
| **Sphere-mapped chrome** | reflection maps looked up per vertex | `psx_chrome.wgsl` with a small matcap | title logos, metal, goggles |
| **Loud 90s graphic design** | chrome type, italic techno faces, saturated accents over muted worlds | [references/textures.md](references/textures.md), "Graphic design" | |

[references/constraints.md](references/constraints.md) has the hardware
behind each row, so a choice that is not in the table can be decided the
way the PlayStation would have decided it.

## What stays modern, and how far

| Modern feature | Use it for | The limit that keeps the look |
|---|---|---|
| 60 frames a second, a depth buffer, no polygon sorting errors | everything: feel and stability | none needed: these were invisible restrictions |
| Screen-space reflections (`ssr_*`) | ice, a frozen lake, wet floors, a chalet's windows, chrome at a distance | only on surfaces flagged reflective ([references/modern.md](references/modern.md)); the reflection passes through the present pass, so it is quantised and dithered with the rest |
| Glow (`glow_*`) | neon signs, the low sun, emissive HUD-like props in the world | on what passes 1.0 only (`emission`, `overbright`); `glow_levels` 1 to 3 at 320 x 240, so the halo is a few blocky pixels, not a soft bloom |
| A lens flare | the low sun | a chain of 3 to 6 flat sprite discs along the sun-to-centre line, `psx_sprite` style, never a physical flare |
| Depth of field (`CameraAttributesPractical`) | replays, the results screen's backdrop, a photo mode | never during play; at 320 x 240 a blur is a few pixels |
| CPU particles | snow spray, powder, sparks, confetti, speed lines | `psx_sprite.wgsl`: nearest, 1-bit alpha, 2 to 6 frame flipbooks; hundreds, not tens of thousands |
| Decals | painted marks on lit (non-PSX) surfaces only | a Decal does not paint `unshaded` surfaces (every PSX surface); use meshes for marks |
| Fog volumes | a mist bank in a valley, a cloud the course drops through | box or ellipsoid volumes, their density stepped; never volumetric light shafts |
| Widescreen | an option | the picture stays 240 lines tall: 426 x 240; the default is 4:3 |
| Analogue precision, rumble, instant restarts | feel | invisible to a screenshot |

## What breaks the look: never

- A smooth, filtered, mipmapped or anisotropic texture on a world surface;
  a PBR material (normal, roughness, metal maps) on a PSX surface.
- A picture drawn at the window's resolution, or upscaled bilinearly
  (the engine's default `scalingMode`); FSR; MSAA on the low-resolution
  view (Hedra does not draw it there anyway).
- Soft shadows, ambient occlusion, real-time shadow maps on the world,
  per-pixel specular highlights, rim lights, subsurface scattering.
- Organic subdivision-surface models, smooth bevels, more than about
  1,000 triangles on any single prop.
- Soft-alpha surfaces (except sprites with an explicit blend), film
  grain, chromatic aberration, CRT curvature or scanlines baked into the
  picture (a CRT filter is an option for the player, off by default, and
  not this skill's).
- Modern UI conventions in the HUD (thin hairlines, frosted glass,
  rounded flat panels): the HUD is the era's too ([references/textures.md](references/textures.md), "Graphic design").

## The frame

The look is made in two places: every surface's shader (snap, affine,
nearest, Gouraud) and one present pass (resolution, 15-bit colour, dither).
Hedra has no post-process shader and presents a scaled 3D picture
bilinearly, so the present pass is a quad:

```
<root>                     main world: black, linear tone map, nothing else
  Screen      Camera3D     the scene's camera
    Present   QuadMesh     psx_present.wgsl, its `screen` the ViewportTexture of LowRes
    Anchor    QuadMesh     1 mm, behind Present: workaround E-VPTEX (below)
  LowRes      SubViewport  320 x 240, render_target_update_mode 4, own_world_3d
    Environment            the game's: depth fog, linear tone map, glow off or low
    Sky                    psx_sky.wgsl on an inverted sphere that follows the lens
    Game                   the game's scene, instanced
    Lens      Camera3D     the game's camera
```

[assets/scenes/psx_frame.rscn](assets/scenes/psx_frame.rscn) is that rig,
ready to copy (with the shaders as `psx/`), and draws as is:

```sh
cp -R $K/psx-style/assets/shaders world/psx
cp $K/psx-style/assets/scenes/psx_frame.rscn world/frame.rscn
hedra render world/frame.rscn -o shots/frame.png --size 1280 720 --msaa off
python3 $K/psx-style/scripts/psx_audit.py frame shots/frame.png --low-res 320x240
```

**Turn MSAA off** in the project: `hedra.yaml`
`rendering/anti_aliasing/quality/msaa_3d: disabled` (Hedra's default is
4x). MSAA does not reach the SubViewport, but on the main view it blends
the present quad's two triangles along their shared diagonal, putting a
few pixels off the 15-bit grid (measured: 5 pixels at 1920 x 1080; none
with MSAA off). `hedra render --msaa off` for the tools.

What the rig costs and changes, measured or read from the engine:

- **Draw cost**: the game is drawn at 76,800 pixels (a sixteenth of
  1280 x 960), the main view one quad: the GPU frame is tiny.
- **Own world**: Hedra's interaction world (`Area3D` signals, `intersectRay`,
  3D listeners) and lightmaps, probes do not reach nodes in an own world.
  Game physics in script (box3d-as) is unaffected. A game that needs
  Hedra's interaction world keeps the world shared and accepts that the
  main camera draws it again unless nothing else is in its view.
- **Billboards** (`ArtboardSprite3D`, a StandardMaterial3D's
  `billboard_mode`) turn to the main view's camera: copy the lens's global
  transform onto `Screen` each frame, or use `psx_sprite.wgsl`, which turns
  its quads in the vertex stage towards whichever camera draws it.
- **Tone mapping**: linear (`tonemap_mode` 0) in both worlds, so colours
  arrive at the present pass as they were authored.
- **Pointer**: a ViewportTexture forwards no pointer event; picking in the
  game world is done in script (rays from the lens).
- **Rive HUD**: drawn by Rive over the Scene3D at the window's resolution,
  on its own 320 x 240 grid scaled by a whole number
  ([references/textures.md](references/textures.md), "Graphic design").

**Preferred, once the engine has it:** `scalingMode: "nearest"` on the
Scene3D (gap E-NEAREST) and a present stage in the engine (gap E-POST)
replace the SubViewport, the quad and the anchor; the shaders stay as they
are.

## Assets through the pipeline

The asset pipeline's stages, gates and approvals hold unchanged
(asset-pipeline: draft, concept, final, each approved by a person). Its
default bar is a modern one (smooth organic shapes, PBR texture sets,
"facets are a blockout's artefact"); for a PSX project these overrides
replace it, and the asset's spec says so in one line ("Style: psx-style").

| Stage | The pipeline's default | For a PSX asset |
|---|---|---|
| **Spec** | parts, sizes, palette, budgets | add: the triangle budget of its class, its texture page (size, CLUT depth), whether it is segmented, its palette as 15-bit hex (every channel a multiple of 8) |
| **Blockout** (model-blockout) | primitives at real scale | unchanged; keep vertex counts as low as the final's (`--vertices 6` or 8): the blockout already shows the polygon budget |
| **Concept** (model-concept) | a fully realised design, natural curves, no facets | a fully realised design **as a 1998 PlayStation render**: low-poly faceted forms, hard edges, chunky proportions, textures that are pixelly and palettised, flat vertex-lit shading; brief from [references/prompts.md](references/prompts.md). The design is still real (a jacket with a hood and pockets, not a box), simplified the PlayStation way: big readable shapes, detail in the texture |
| **Base textures** | one tileable 1024 texture per material | generated at 1024 from the PSX texture brief, then **fitted, not converted to PBR**: `psx_texture.py` to 64 or 128 px, 16 colours on the 15-bit grid, 1-bit alpha; no normal or ORM maps ([references/textures.md](references/textures.md)) |
| **texture-from-concept** | albedo, normal, ORM, `.mtlx` | **skipped**: a PSX material is a `ShaderMaterial` of `psx_surface.wgsl` (or `psx_cutout`, `psx_chrome`) with its texture and tint; values come from the concept's palette, not from PBR tables |
| **Final** (model-final) | smooth, subdivided, bevelled, PBR | inside the triangle budget, faceted where the concept is, segmented if a character, UVs packed to the texture page (one 128 x 128 page per prop where possible), flat or smooth normals chosen per part, `meshes/generate_lods=false` |
| **Fidelity gate** | the final against the concept, rendered with materials | unchanged thresholds, but the final's sheet is rendered **through the PSX frame** (the four views inside `psx_frame.rscn`'s `LowRes`, at 320 x 240, upscaled nearest), so the comparison is pixel look against pixel look; the "untextured share" check still applies: a PSX final is textured everywhere the concept is |
| **Raster assets** (raster-asset) | generated, fitted, checked | generated from the PSX brief, fitted with `psx_texture.py` (sprites, decals, sky strips, signage), or with `raster_fit.py --colors` for UI pieces drawn at whole multiples of 320 x 240 |
| **2D graphics** (graphic-*) | RML vector, modern | the era's graphic design on a 320 x 240 grid: chrome, bevels, italic techno type, hard drop shadows; pixel fonts at whole scales ([references/textures.md](references/textures.md)) |

## The gates

Each is a command; a PSX asset passes the pipeline's gates and these.

```sh
P=$K/psx-style/scripts
python3 $P/psx_audit.py texture final/textures/snow.png --max-colors 16
python3 $P/psx_audit.py model final/rider.rmdl --max-tris 500 --max-object-tris 120
python3 $P/psx_audit.py frame shots/run_0420.png --low-res 320x240
```

- **texture**: a power of two from 8 to 256 a side, at most the CLUT's
  colours, every channel on the 15-bit grid, alpha 0 or 255 only, imported
  lossless without mipmaps.
- **model**: the class's triangle budget, the object count, the largest
  part.
- **frame**: a screenshot of the running game: inside the pillarbox, at
  least 98 % of the low-resolution pixels are solid blocks, every channel
  on the 15-bit grid (pass `--max-off-grid` a small share when the Rive
  HUD is in the shot), the 4:3 aspect kept. The brief's "a screenshot is
  recognised as a PS1 game" made measurable; a person still looks.

Then look at every frame at 1x and at 3x nearest: a smooth gradient that
should band, a surface that does not swim, a texture that is too fine for
its 64 pixels, a modern effect that is too soft. No metric sees taste.

## Light and colour

- **One sun, one sky, one bounce.** `sun_direction` and `sun_color`, a
  `sky_ambient` and a `ground_ambient`, the same values in every PSX
  material of a scene (one place in the generator that writes the scene;
  a time of day is new values written to all of them, by keys or a
  script).
- **Fog is the sky's horizon colour**, and the sky's `horizon` uniform is
  the Environment's `fog_light_color`, so far geometry melts into the sky.
- **Palette**: a muted, mid-value world (snow, stone, wood, pine) under
  two or three saturated accents (hot pink, acid green, orange, cyan) that
  belong to things the player must see: the rider, the gates, the rails,
  the banners. Every colour in a spec is 15-bit (#f8f8f8 is the
  PlayStation's white).
- **No black shadows**: the ambient keeps the darkest lit face above
  about 20 % value; contrast comes from the palette, not from the light.

## Engine gaps and their workarounds

Found while building this skill against hedra 0.1.0; each has a
workaround that is in the files above.

| Gap | What is missing | Workaround here |
|---|---|---|
| E-NEAREST | a Scene3D picture smaller than its layout is stretched bilinearly; no `scalingMode: "nearest"` (the presentation already samples nearest when the picture is the layout's size: `engine/src/render/gpu/renderer.as`, `redraw`) | the SubViewport rig |
| E-POST | no post-process (screen) shader; `hint_screen_texture` refused | the present quad over a ViewportTexture |
| E-VPTEX | a ViewportTexture named only by a ShaderMaterial parameter samples black (`inspect --viewports`: "shown by no texture"), though SHADERS.md says it is live | the 1 mm anchor quad naming it in a StandardMaterial3D slot |
| E-AFFINE | no `noperspective` or `flat` varyings | `(uv * w, w)` divided per pixel |
| E-VLIGHT | `render_mode vertex_lighting` is ignored; engine lights are not readable in `vertex()` | the sun and ambient as uniforms, lit in `vertex()` |
| E-VCOLOR | meshes carry no vertex colours (`COLOR` is white), so no baked vertex light or vertex-painted tint | tint per material (`albedo`), light baked into the texture, or a palette-swatch texture whose UVs pick colours |
| E-FRAME | the shader world is Z up (scene (x, y, z) is (x, -z, y)) | `scene_to_frame()` in each shader; uniforms are given Y up |
| E-FLIP | no particle flipbook, no particle age in a shader | the age carried in `COLOR.a` by the emitter's `color_ramp` (`psx_sprite.wgsl`) |
| E-DECAL | Decals do not paint unshaded surfaces | `psx_blob_shadow.wgsl` on a mesh |
| E-WARN | `particles-vertex-color` warns for a ShaderMaterial although `COLOR` does reach it | ignore it for `psx_sprite` |
| E-LMAP | a ShaderMaterial has no lightmap variant | Gouraud from uniforms; bake light into textures where it matters |

## Files

```
psx-style/
  SKILL.md                         this
  references/constraints.md        the hardware, and what each limit looks like
  references/shaders.md            every shader: parameters, assignment, recipes, costs
  references/textures.md           texture style, sizes, palettes, pages; the graphic design
  references/models.md             budgets, topology, characters, trees, UVs, imports
  references/prompts.md            image-generate briefs for PSX concepts, textures, sprites
  references/modern.md             reflections, glow, flares, particles, fog volumes, DOF
  assets/shaders/*.wgsl            psx_surface, psx_cutout, psx_chrome, psx_sky,
                                   psx_blob_shadow, psx_sprite, psx_present
  assets/scenes/psx_frame.rscn     the frame rig, ready to copy
  scripts/psx_texture.py           an image to a PSX texture (size, CLUT, 15-bit, 1-bit alpha)
  scripts/psx_audit.py             texture, model and frame gates
```

The scripts need Python 3 with Pillow and NumPy (`pip install pillow
numpy`), as the asset pipeline's do, and `hedra` on the PATH for the model
audit. `$K` is the skills directory; the asset pipeline's skills
(`rive_modeler/skills/install.sh --dir .claude/skills`) and hedra's own
(`hedra skill install --dir .claude/skills`) are installed beside this one.

## Rules that outrank taste

**The restrictions are the style.** Resolution, colour depth, jitter,
warp, texel size and vertex light are kept exactly; none is softened to
look "better".

**Modern where it is invisible or where it is quantised.** Frame rate,
depth buffer, input and physics are modern; every modern effect is drawn
inside the low-resolution frame and goes through the 15-bit present pass.

**Detail lives in the texture, not the mesh.** A shape the silhouette does
not need is painted, at 64 to 128 pixels, in 16 colours.

**One sun, one fog, one palette per scene**, written once and shared by
every material.

**Measure the frame, then look at it at 1x.** `psx_audit.py frame` on a
real screenshot, then a person's eye.
