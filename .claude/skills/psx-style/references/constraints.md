# The hardware, and what each limit looks like

The PlayStation (1994) drew 3D with a geometry coprocessor (the GTE) and a
2D rasteriser (the GPU) that knew nothing of depth or perspective. Every
trait of the look is one of their limits. When a choice is not in
SKILL.md's tables, decide it the way this hardware would have.

| Part | The limit | What it looks like | Kept here as |
|---|---|---|---|
| GTE | fixed-point maths; vertices projected to whole screen pixels (no sub-pixel precision) | polygons wobble and jitter as the camera moves; edges crawl; thin geometry shimmers | `snap_view()` to `snap_resolution` |
| GTE | perspective division per vertex only | (with the GPU's interpolation) textures swim and bend on large or near polygons | affine UV, `affine_strength` |
| GTE | 1 to 1.5 million vertex transforms a second in practice: 3,000 to 5,000 lit, textured triangles a frame at 30 fps | blocky silhouettes, few trees, short view distance, levels built from big pieces | triangle budgets (models.md) |
| GPU | draws 2D triangles and quads with screen-space (affine) interpolation of UV and colour | the warp; Gouraud colour interpolated per triangle, so a quad's light differs along its diagonal | affine UV; Gouraud in `vertex()` |
| GPU | no depth buffer: polygons sorted per object or per polygon (ordering tables) | polygons popping through each other, near-plane clipping holes | **not kept**: the depth buffer is modern and invisible when right |
| GPU | no texture filtering, no mipmaps | crisp texels close up, sparkling and moiré at a distance | `filter_nearest`, no mipmaps |
| GPU | 1 MB of VRAM, shared by the two framebuffers and every texture: textures in 256 x 256 pages, 4-bit (16-colour) or 8-bit (256-colour) palettes (CLUTs), 15-bit colour | small textures (32 to 128 px a side), heavy reuse and tiling, palette swaps for colour variants | 64 to 128 px, 16 colours, the 15-bit grid (`psx_texture.py`) |
| GPU | 15-bit framebuffer (5 bits a channel), its shaded and blended pixels dithered with a fixed 4 x 4 table | banding on gradients, a fine dither grid in skies, fog and shading | `psx_present.wgsl` with the PlayStation's table |
| GPU | resolutions 256 to 640 wide, 240 or 480 lines; most 3D games 320 x 240 (NTSC) | big pixels; no anti-aliasing: stair-stepped edges | 320 x 240, nearest upscale |
| GPU | semi-transparency in four fixed modes (0.5B + 0.5F, B + F, B - F, B + 0.25F) and "colour 0 is transparent" | additive glows and shadows, cut-out foliage, no soft alpha | 1-bit alpha (`ALPHA_SCISSOR_THRESHOLD`), `blend_add`, `blend_mul` |
| GPU | colour modulation of textures by vertex colour, 128 being 1.0 | textures brightened up to 2x by the light: "overbright" highlights | `overbright` up to 2 |
| GTE | depth cueing: vertex colour blended towards a far colour by depth | fog that hides the far clip, its colour the sky's | the Environment's depth fog |
| Lighting | done by the GTE per vertex: a few directional lights, an ambient, no shadows | soft, vertex-wide light; faceted spheres; no cast shadows | the sun and the hemisphere ambient in `vertex()`; blob shadows |
| Memory | 2 MB of RAM for everything | segmented rigid characters (no skinning), 2 to 6 frame sprite animations, repeated props | segmented characters, flipbooks |
| Video | composite or RF to a CRT at 60 Hz (NTSC); games at 30 or 20 fps | softness and colour bleed on real TVs; low frame rates | **not kept** by default: 60 fps; a CRT filter only as a player's option |
| Audio | the SPU: 24 voices of 4-bit ADPCM samples, up to 44.1 kHz but usually 11 to 22 kHz, a hardware reverb | lo-fi, short, looped samples; a characteristic reverb | the game's audio spec (procedural synthesis voiced through an SPU-like chain) |

## What to keep, what to drop

Keep a limit when a screenshot shows it (resolution, colour depth, the
dither, jitter, warp, texel size, vertex light, fog, low polygons, 1-bit
alpha). Drop a limit when only its failure would be visible and the
failure reads as a bug rather than a style (no depth buffer, near-plane
holes, 20 fps, load times, memory-card saves).

## Numbers worth knowing

- 320 x 240 is 76,800 pixels; 4:3 on a 16:9 screen leaves bars a quarter
  of the width wide in total.
- 15-bit colour: 32 levels a channel; the brightest value is 248 (31 x 8),
  so the PlayStation's white is #f8f8f8.
- The PlayStation's dither offsets (psx-spx, "GPU Dithering"), in 8-bit
  steps, for x % 4 across and y % 4 down:

  ```
  -4  +0  -3  +1
  +2  -2  +3  -1
  -3  +1  -4  +0
  +3  -1  +2  -2
  ```

- A 4-bit texture page entry of 64 x 64 is 2 KB; a 128 x 128 is 8 KB. A
  whole game level lived in a few hundred KB of textures.
- Frame budgets of shipped games, for scale: a racing car 300 to 800
  triangles, a character 300 to 600, a whole visible scene 2,000 to 5,000.
