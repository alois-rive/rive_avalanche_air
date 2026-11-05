# Modern features inside the PSX frame

Every modern effect is drawn inside the 320 x 240 SubViewport, so the
present pass quantises and dithers it with everything else: a reflection
becomes a few dithered blocks, a glow a blocky halo. That is what keeps
them in the look. Each recipe below says how far to go.

Check each in the project's look lab before it ships: Hedra draws a
SubViewport "with its shadows, its sky and its post-processing", and a
custom shader writing a low `ROUGHNESS` takes part in screen-space
reflections, but the combination with this skill's `unshaded` shaders is
not measured here.

## Screen-space reflections

For ice, a frozen lake, wet floors, polished floors of a lodge, chrome at
a distance.

- On the game's Environment: `ssr_enabled` true, `ssr_max_steps` 16 to 32
  (the picture is 320 x 240: few steps reach across it),
  `ssr_fade_in` 0.15, `ssr_fade_out` 2.0, `ssr_depth_tolerance` 0.2.
- The reflective surface is a lit variant of psx_surface: copy it, drop
  `unshaded`, write `ROUGHNESS` 0.05 to 0.2 and `METALLIC` 0, and keep the
  Gouraud colour as `ALBEDO`. Nothing rougher than 0.6 is traced.
- Keep reflective surfaces few and flat; a PlayStation player has never
  seen a reflection, so it reads as a treat, not as the norm.

## Glow

For the low sun, neon signs, a finish arch's lights, emissive markers.

- `glow_enabled` true, `glow_levels/1` to `/3` only (at 320 x 240 higher
  levels are a haze over the whole picture), `glow_hdr_threshold` 1.0,
  `glow_intensity` 0.6 to 1.0, `glow_blend_mode` 0 (additive).
- Only what passes 1.0 glows: `emission` and `overbright` on psx_surface,
  the sun disc of psx_sky (1.4).

## A lens flare

A chain of 3 to 6 flat discs and rings (a 64 x 16 sheet of 4 shapes),
quads in front of the lens placed each frame by a script along the line
from the sun's screen position through the centre, `blend_add`, fading as
the sun leaves the frame or goes behind something (a ray from the lens to
the sun). Never a physical flare, never streaks.

## Particles

- `CPUParticles3D` with a 1 x 1 `QuadMesh` in `psx_sprite.wgsl`: nearest,
  1-bit alpha, a 2 to 6 frame flipbook driven by the `color_ramp`'s alpha.
- Hundreds at once at most: each is several pixels at 320 x 240; spray
  reads from 20 to 60 big sprites, not 2,000 small ones.
- `local_coords` false for trails left behind (spray, powder), true for
  what moves with its emitter (sparks on a rail).

## Speed lines

Thin dark or white quads (or a ring of stretched sprites,
`particle_flag_align_y`) streaming past the lens's edges when the player
goes fast, drawn in the SubViewport so they are pixel-sized.

## Fog volumes

A `FogVolume` (box or ellipsoid) for a cloud bank the course drops
through or mist in a valley: `density` stepped (0.02 to 0.08), `albedo`
the fog colour, `volumetric_fog_enabled` on the game's Environment. Never
light shafts. Fog volumes cost on the web: one or two.

## Depth of field

`CameraAttributesPractical` on a replay or menu camera only: the results
screen's backdrop, a photo mode. At 320 x 240, `dof_blur_amount` 0.05 to
0.1 is already strong. Never during play.

## Real-time shadows

None on the world. A hero prop that must cast one (a gondola over the
course) gets a blob or a projected quad, as the era did.

## Frame rate and widescreen

- 60 frames a second, always: input and camera feel are not part of the
  look's restrictions.
- Widescreen as an option: the SubViewport at 426 x 240, `low_res` 426 x
  240 on the present pass, `snap_resolution` 426 x 240 on the shaders;
  the default stays 4:3 at 320 x 240.

## Higher internal resolution

An option for players who want it ("Hi-res: 640 x 480"): the SubViewport,
`low_res` and `snap_resolution` doubled. The default and every reference
screenshot stay 320 x 240.
