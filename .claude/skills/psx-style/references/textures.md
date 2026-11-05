# Textures, palettes and the era's graphic design

A PSX texture is small, palettised and painted to be seen at its own
size: every texel is a decision. The image generator paints big and
smooth; `psx_texture.py` brings it down to the PlayStation's terms, and
the brief asks for what survives that trip.

## Sizes and depths

| Use | Size | CLUT | Notes |
|---|---|---|---|
| Terrain tile (snow, rock, grass) | 64 x 64 | 16 | tiles at 2 to 4 m; a few large, distinct features, no fine noise |
| Wall, roof, plank, metal tile | 64 x 64 | 16 | tiles at 1 to 2 m |
| A prop's page (a chalet, a lift pylon, a sign) | 128 x 128 | 16 | one page per prop: every face's region packed in it |
| A character's page | 128 x 128 | 16 (256 for a face drawn large) | the whole rider: jacket, trousers, face, gloves, board's base |
| A board graphic, a sponsor banner, a logo on a prop | 128 x 64 or 128 x 128 | 256 | text and logos need the 8-bit palette |
| A tree (crossed quad) | 64 x 128 | 16 | 1-bit alpha; the trunk and three to four tiers of branches |
| A sprite sheet (spray, sparks, confetti) | 64 x 16 (4 frames of 16), 128 x 32 | 16 | 1-bit alpha, frames left to right |
| A sky strip (mountains, a skyline) | 128 x 32 to 256 x 64 | 16 | 1-bit alpha at its top edge |
| A matcap (chrome) | 64 x 64 | 16 to 32 | sky band, dark horizon line, warm ground, one highlight |

Nothing above 256 a side (a texture page). A colour variant (three jacket
colour schemes) is the same texture with another `albedo` tint or a
palette swap (`psx_texture.py` again from a recoloured source), never a
bigger texture.

## What survives at 64 pixels

- **Big, readable shapes**: a plank is 6 to 8 texels tall, a brick 4 x 8,
  a snow sastruga 10 to 20 texels long. Detail under 2 texels becomes
  noise.
- **Value structure first**: three to five values a material (shadow
  side, mid, light, highlight), then hue.
- **Hand-placed highlights and dark accents**: a lit edge on a plank, a
  dark gap between logs: the light the vertex shading will not draw.
- **Light baked in, mildly**: the texture may carry a little top-light and
  occlusion in its crevices (the era's textures did); the scene's sun is
  added on top by the vertex light, so keep it soft.
- **Saturation where the eye should go**: muted materials, saturated
  accents (signage, the rider, the gates).

## From a generated image to a PSX texture

```sh
python3 $K/image-generate/scripts/generate.py \
    --prompt-file concept/textures/snow.v1.prompt.md --out concept/textures/snow.v1.png
python3 $K/psx-style/scripts/psx_texture.py concept/textures/snow.v1.png final/textures/snow.png \
    --size 64x64 --colors 16 --tileable
hedra import final/textures/snow.png --set compress/mode=lossless --set mipmaps/generate=false
python3 $K/psx-style/scripts/psx_audit.py texture final/textures/snow.png --max-colors 16
```

| Flag | Use |
|---|---|
| `--size WxH` | powers of two, 8 to 256 |
| `--colors N` | the CLUT: 16 (4-bit) for nearly everything, 256 for text, faces, logos |
| `--resample box` | the default: averages honestly (a Lanczos ringing halo becomes palette entries) |
| `--resample nearest` | for a source already drawn as pixel art on a grid |
| `--dither ordered` | for gradients that must not band inside the texture (a sky strip, a chrome matcap) |
| `--dither floyd` | for painted textures with soft transitions; usually `none` is best |
| `--tileable` | hides the wrap seam before downscaling |
| `--key-bg`, `--bg`, `--tolerance` | 1-bit alpha: the flat background joined to the border is cut |
| `--mode contain` | a sprite or a tree that must not be cropped |

The import line keeps every texel: block compression (BC, ETC2, ASTC)
would smear a 16-colour palette, and mipmaps would filter it.

Then look at it tiled 3 x 3 at 4x nearest: a feature that repeats like
wallpaper (one bright rock four times) is a texture to regenerate with
less singular features; a texture that reads as noise at 1x is too fine.

## Palettes

Every colour of a spec is 15-bit: each channel a multiple of 8, 0 to 248.
A scene's palette is written once (the spec's table) and the textures'
CLUTs drift around it.

- The world in muted mid values; the accents saturated and few.
- Shadows are coloured (blue-grey on snow, purple at dusk), never black.
- Fog, sky horizon and far textures converge on one colour.
- A colour scheme (the rider's three jackets) is a palette swap of the
  same texture.

## Graphic design: the HUD, the menus, the logo

The 2D is the era's too, and it is drawn by Rive (RML, the asset
pipeline's 2D track) on top of the 3D. It sits on a **320 x 240 grid**
scaled by a whole number (2x at 640 x 480, 3x at 960 x 720, 4x at
1280 x 960, the remainder as bars), so the type and panels line up with
the 3D's pixels.

- **Type**: wide, italic, techno faces for titles and trick names (heavy
  extended italics, slanted 10 to 15 degrees), with a hard 1-to-2-pixel
  drop shadow and a 1-pixel dark outline; a pixel font for numbers and
  small labels, set at whole multiples of its design size. No anti-aliased
  thin type, no hairlines.
- **Chrome**: chrome gradients (sky, a dark horizon line, warm ground,
  a highlight) on title letters and grade stamps, as a 2D gradient in
  RML or as the 3D logo in `psx_chrome.wgsl`.
- **Panels**: bevelled or slanted shapes in saturated colours with hard
  edges; translucency only as the era's 50 % mode; no blur, no rounded
  flat cards.
- **Motion**: slams, scale bounces past 100 % and back, quick flashes,
  spinning 3D logos; everything snapped to the grid's pixels while it moves.
- **Colour**: the scene's accents (hot pink, acid green, orange, cyan) on
  black or deep blue; white numbers with dark outlines.

A raster UI piece (a grade stamp, a logo) is generated from the PSX brief
and fitted with `raster_fit.py --colors 32` at its 1x pixel size (its size
on the 320 x 240 grid), then drawn by Rive at the whole scale with a
nearest sampler.
