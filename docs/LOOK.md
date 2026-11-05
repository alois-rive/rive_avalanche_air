# The look

Avalanche Air must read as a 1998 PlayStation game from one screenshot
(the brief's fourth success criterion). The rules are the project skill
[psx-style](../.claude/skills/psx-style/SKILL.md), generic to any
PSX-looking Hedra project; this document applies them to this game: which
shader each surface wears, the palette, the sunset, the rider, the
effects, the modern extras and their limits. Read the skill first.

## 1. The frame

| Setting | Value |
|---|---|
| Internal resolution | 320 x 240 (the default and every reference shot); 426 x 240 as the widescreen option; 640 x 480 as a "hi-res" option |
| Upscale | nearest, pillarboxed (black bars), `integer_scale` on when the window allows a whole multiple |
| Colour | 15-bit, the PlayStation's dither (`color_bits` 5, `dither_strength` 1) |
| Frame rate | 60 fps |
| Rig | psx-style's `psx_frame.rscn`: the run's world in the `LowRes` SubViewport (its own world), the present quad on `Screen`, the anchor quad (gap E-VPTEX) |
| Tone map | linear in both worlds |
| Anti-aliasing | none: `rendering/anti_aliasing/quality/msaa_3d: disabled` in `hedra.yaml` (on the main view MSAA blends the present quad's diagonal off the 15-bit grid) |

`world/run.rscn` is the frame rig with the course (`course/course.rscn`),
the rider and the cameras instanced under `LowRes`. The Scene3D on the
`Main` artboard draws `run.rscn` (RIVE.md, section 1).

**Once the engine has E-NEAREST and E-POST** (SPEC.md, section 13) the
rig gives way to the Scene3D drawn at 320 x 240 with `scalingMode`
nearest and a present stage; the shaders and every value below stay.

**The HUD's grid.** The Rive HUD is laid out on the same 320 x 240 grid
(426 x 240 in widescreen), scaled by the whole number that fits the
window, so its pixels are the 3D's pixels (RIVE.md, section 7).

## 2. The palette

Every colour is 15-bit (each channel a multiple of 8). The world is muted;
the accents belong to what the player must see.

| Role | Colours |
|---|---|
| Snow, lit to shade | #f8f8f8, #e0e8f8, #c8d0f0, #a8b8e0, #8898c8, #7080b0 |
| Rock, bark, wood | #585068, #706070, #886848, #a07850, #c09868 |
| Pine | #183830, #285040, #387050, #509060 |
| Accents | hot pink #f83890, acid green #a8f830, orange #f88818, cyan #30d8f8 |
| Neon (emissive) | pink #f850b0, cyan #50f0f8, yellow #f8f058 |
| Fog by day / at dusk | #c8d8f0 / #7858a0 |
| UI ground | #000000, deep blue #101848 |

The accents mark the rider (the scheme's jacket), the gates and arches,
the rails and boxes (pink and orange), the kickers' lip lines (green), the
banners. Nothing else is saturated.

## 3. Light, fog and the sunset

One sun, one sky, one bounce per scene (psx-style, "Light and colour"),
changing with the progress along the line (COURSE.md, section 7): the run
starts in afternoon gold and ends in a purple dusk.

- **The parameters**: on every PSX material, `sun_direction`, `sun_color`,
  `sky_ambient`, `ground_ambient`; on the sky, `zenith`, `horizon`,
  `sun_direction`, `sun_color`; on the game's Environment,
  `fog_light_color`, `fog_depth_begin` and `fog_depth_end`.
- **How they change**: a timeline `Daylight` in the world, 1 s long, keyed
  by the course generator at COURSE.md's keyframes (s / 1,420 of the
  second), on every PSX material's parameters
  (`mesh:material:shader_parameter/<name>`, `material_override:...`) and
  on the Environment; `run.as` sets its time from the rider's progress
  each frame. The generator writes the keys, so a keyframe is one number
  in `course.py`. (A0 checks that a key on a material shared by many
  meshes changes them all; if a material must be keyed per instance, the
  generator writes those keys instead.)
- **Fog**: depth fog, `fog_depth_begin` 35 m and `fog_depth_end` 140 m by
  day, closing to 25 m and 110 m at dusk; its colour the sky's `horizon`.
  The far mountains are the sky's horizon strip and three low-poly
  ridges inside the fog's end.
- **No shadows** but the blob under the rider (section 5); obstacles and
  trees cast none. The chalets' and the station's undersides are darker
  by the hemisphere ambient.

## 4. Surfaces

Every surface wears one of the skill's shaders with a PSX texture (64 or
128 px, 16 colours unless said, lossless, no mipmaps).

| Surface | Shader | Texture | Notes |
|---|---|---|---|
| Groomed piste | `psx_surface` | `snow_groomed` 64 x 64, corduroy lines | `uv_scale` one repeat every 3 m, along the line |
| Powder (off-piste) | `psx_surface` | `snow_powder` 64 x 64, soft drifts | one repeat every 4 m |
| Kicker faces, tables, landings | `psx_surface` | `snow_packed` 64 x 64 | the lip marked by a 0.3 m acid-green line (a texture row) |
| Rock bands, cliffs | `psx_surface` | `rock` 64 x 64 | `light_bands` 0 |
| Frozen lake | a lit copy of `psx_surface` (section 6) | `ice` 64 x 64 | reflective |
| Pines (crossed quads) | `psx_cutout` | `pine_a`, `pine_b` 64 x 128, 1-bit alpha | two snow variants |
| Pines near the high line (cone stacks) | `psx_surface` | `pine_cone` 64 x 64 | |
| Chalets, the lodge, the start hut | `psx_surface` | a 128 x 128 page each (planks, windows, snow on the roof) | windows `emission` warm at dusk |
| Lift pylons, chairs, gondola cabins | `psx_surface`; cabins' windows `psx_chrome` | a shared 128 x 128 page | |
| Rails, handrail | `psx_chrome` | `chrome_matcap` 64 x 64 over pink | 6-sided tubes |
| Boxes | `psx_surface` | `box` 64 x 64, orange with sponsor stripes | |
| Logs | `psx_surface` | `bark` 64 x 64 | 8-sided |
| Sponsor banners | `psx_surface` | 128 x 64, 256 colours, fictional sponsors (section 8) | `uv_scroll` off |
| Inflatable arches | `psx_surface` | 128 x 128, 256 colours | `overbright` 1.3 |
| Finish arch's neon | `psx_surface` | `neon` strip | `emission` neon pink and cyan: the glow catches it |
| Snow fences, flags | `psx_cutout` | 64 x 32, orange mesh | |
| Crowd | `psx_cutout` crossed quads | `crowd` 128 x 64, 4 variants in one sheet | |
| Sky | `psx_sky` | `mountains` horizon strip 256 x 64 | the sphere follows the lens |

## 5. The rider

- **Model**: 15 rigid parts (pelvis, chest, head, beanie with goggles,
  upper and lower arms, hands, upper and lower legs, boots) and the board,
  about 480 triangles with the board's 40; segmented, the joints
  overlapping a little, the seams visible (psx-style models.md,
  "Characters").
- **Texture**: one 128 x 128 page, 16 colours (the face 8 x 8 texels on the
  head's front: goggles, a grin); the board's base a separate 64 x 128
  (256 colours, the Avalanche Air graphic) on its underside, seen in
  every flip.
- **Schemes**: Hot Pink, Acid, Blaze (SPEC.md, section 5) are palette
  swaps of the page (three textures, made from one source by
  `psx_texture.py` with the scheme's colours), chosen on the title.
- **Shader**: `psx_surface` on every part; `snap_resolution` 320 x 240 like
  everything (the rider jitters too: authentic); `overbright` 1.2 so the
  jacket pops against the snow.
- **Blob shadow**: `psx_blob_shadow` on a 1.4 m plane under the board,
  placed each tick by a ray down, its `lift` from the height above the
  snow (0 at 0 m, 1 at 6 m); `shadow_color` #8898c8 by day, #605890 at
  dusk.
- **Ghost and respawn blink**: a 1-bit screen-door transparency (a 2 x 2
  pattern of discarded pixels on the low-resolution grid: `psx_surface`'s
  `screen_door`, 0.5 for the ghost, blinking 0 and 0.75 at 8 Hz for the
  respawn), the era's translucency for characters.

## 6. Effects

| Effect | How | Budget |
|---|---|---|
| Snow spray from the edge | `CPUParticles3D` under the board's tail, `psx_sprite` (a 4-frame puff, 16 px frames), emitting with the carve's lateral demand and twice on a skid, `local_coords` off | 48 live |
| Powder burst on landing | a one-shot emitter, 24 puffs, size by impact | 2 at once |
| Board trail | quad segments (`psx_blob_shadow` style multiply, a pale blue) laid behind the board on the snow, the oldest reused | 24 segments of 1 m as `MeshInstance3D`s moved by script, fading after 3 s; 96 in one `MultiMesh` once E-MULTI lands (PERF.md, section 5) |
| Speed lines | a ring of 24 stretched white sprites at the lens's edges (`particle_flag_align_y`), emitting from 22 m/s in a tuck | 24 |
| Lens flare | 5 flat discs and rings (a 64 x 16 sheet), `blend_add`, on the line from the sun's screen position through the centre, faded by a ray to the sun (psx-style modern.md) | 5 quads |
| Perfect landing sparkle | 6 star sprites on the board, 0.4 s | |
| Rail sparks | 12 tiny sprites at the board on a rail, orange | |
| Confetti at the finish | 2 cannons, 120 confetti (4 colours, 2 frames) | 240 |
| Neon glow | the Environment's glow, `glow_levels/1` and `/2` only, threshold 1.0, on the finish arch, the mega-jump's arch, the low sun's disc | |
| Snow falling at dusk | 150 slow flakes round the lens from s = 1,000 | 150 |
| The snow wipe | a Rive overlay over the 3D (RIVE.md, section 5): a white diagonal wipe hiding a respawn | |

Every particle is drawn inside the SubViewport, so it is a few blocky
pixels, dithered: a thousand of them would be mush; tens read.

## 7. The modern extras, and their limits

| Extra | Where | Limit |
|---|---|---|
| Screen-space reflections | the frozen lake below the rail garden; the lodge's windows at the finish | `ssr_max_steps` 24; the lake is a lit copy of `psx_surface` writing `ROUGHNESS` 0.08, `METALLIC` 0 and the Gouraud colour as `ALBEDO`; checked in A0's look lab (psx-style modern.md) |
| Glow | neon, the sun disc | levels 1 and 2 |
| Lens flare | the low sun | flat discs only |
| Depth of field | the results screen's backdrop (the finish camera, blurred behind the tally) | never during the run |
| Fog volume | one box at the high line's drop HD2: a cloud bank the rider drops through | density 0.04, stepped |
| 60 fps, widescreen, hi-res | options (widescreen and hi-res off by default) | the reference shots are 4:3 at 320 x 240 |

## 8. Graphic design (the 2D)

Drawn by Rive, on the 320 x 240 grid (psx-style textures.md, "Graphic
design"); RIVE.md has the layouts.

- **Logo**: "AVALANCHE AIR" in heavy extended italic letters, chrome
  (`psx_chrome` on a 3D extruded logo of about 600 triangles for the title,
  spinning; a 2D raster for small uses), a pink outline, a hard shadow.
- **Type**: a wide italic techno display face for trick names, praise
  words and the grade; a pixel font for numbers and labels, set at whole
  multiples. Both under a licence that allows embedding (SIL OFL), chosen
  at A0 from candidates (ASSETS.md, section 6).
- **Trick names** slam in: scale 160 % to 92 % to 100 % over 0.25 s, a
  hard drop shadow, the name in white with a pink outline; the praise word
  in acid green with an orange outline below it.
- **Grade stamp**: a chrome letter (S gold-chrome, A pink, B cyan, C
  grey) slammed from 300 % with a screen shake of 2 pixels (none with
  reduced motion) and a dust burst.
- **Sponsors**: fictional, made for the game (no real brand): "FROSTBYTE
  WAX", "NEON PEAK RESORT", "AVALANCHE AIR", "CHILLWAVE SODA", "POW!
  GOGGLES", "RADICAL ENERGY". Generated textures are checked by the person
  for invented real brands before they ship (image-generate, "Review").

## 9. The look's checks

- `psx_audit.py texture` on every texture, `model` on every model with
  its class budget (ASSETS.md), `frame` on the eight reference shots
  (SPEC.md, section 14, item 5; `--max-off-grid 0.02` for those with the
  HUD in them).
- The reference shots at 1x and 3x beside the brief, reviewed by the
  person at A6.
- The blind "is it a PlayStation game?" check (SPEC.md, section 14, item
  10).
