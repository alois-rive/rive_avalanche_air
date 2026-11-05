# Assets

Every model, texture, sprite and 2D component goes through the Hedra
asset pipeline (`rive_modeler/skills/`: asset-pipeline, image-generate,
model-blockout, model-concept, model-final, raster-asset, graphic-draft,
graphic-concept, graphic-final): a draft, a generated concept, a final
rebuilt with the tools, each gated and **approved by a person**
(`asset.py approve`; an agent never approves). Every asset's spec says
"Style: psx-style", and the project skill
[psx-style](../.claude/skills/psx-style/SKILL.md) overrides the pipeline
where the PlayStation look departs from its modern default ("Assets
through the pipeline"): PSX concepts, palettised textures instead of PBR
sets, triangle budgets, the fidelity sheet rendered through the PSX frame.

What is not an asset: the course's geometry (terrain, kickers, rails,
boxes, logs, far ridges: made by the course generator, COURSE.md, section
10, wearing the pipeline's textures), the rider's poses (data,
RIDER.md, section 12) and every sound (synthesised, AUDIO.md).

## 1. Where they live

```
assets/<asset>/                 one per asset, the pipeline's layout
  asset.json                    the manifest (asset.py)
  <asset>.spec.md               the numbers: parts, sizes, budget, palette (15-bit hex), "Style: psx-style"
  draft/ concept/ final/ shots/ (generated/ for raster assets)
assets/index-models.png         every model's approved concept and final, one sheet
assets/index-2d.png             every 2D component
assets/index-raster.png         every texture at 4x, tiled 2 x 2 where it tiles
tools/sync_assets.py            copies each approved final into world/ (models, textures and
                                their .import) or ui/ (2D), refusing an asset whose
                                `asset.py status` or `psx_audit.py` fails
```

Install the skills once (`rive_modeler/skills/install.sh --dir
.claude/skills` and `hedra skill install --dir .claude/skills`); psx-style
is already in `.claude/skills/`.

## 2. Models (the 3D track)

| Asset | What | Triangles | Texture | Notes |
|---|---|---|---|---|
| `rider` | the snowboarder: 15 rigid parts and the board | 480 (the board 40) | one 128 x 128 page, 16 colours; the board's base 64 x 128, 256 colours | segmented; three schemes as palette swaps (LOOK.md, section 5); the concept sheet shows the rider in the four views and a fifth panel in a grab |
| `logo3d` | "AVALANCHE AIR", extruded, bevelled once | 600 | the chrome matcap over pink | the title's spinning logo |
| `chalet-a`, `chalet-b` | the start's and the finish's chalets | 300 each | a 128 x 128 page each | roofs with snow, lit windows (emission at dusk) |
| `lodge` | the finish lodge, a terrace with the crowd | 500 | a 128 x 128 page | |
| `start-hut` | the start gate's hut and the gate | 160 | a 64 x 64 page | the gate's bar lifts at GO (a timeline) |
| `lift-pylon`, `lift-chair`, `lift-station` | the chairlifts | 80, 40, 300 | one shared 128 x 128 page | chairs instanced |
| `gondola-pylon`, `gondola-cabin`, `gondola-station` | the gondola and its station (the HG gap's roof) | 100, 120, 450 | one shared 128 x 128 page | the station's roof is ridden: its collision is the generator's |
| `arch` | the inflatable arch | 200 | three 128 x 128 textures (start, split, finish) | the finish's with neon |
| `banner` | a span banner on two posts; a post banner | 40, 16 | the sponsor textures (section 3) | |
| `pine-cone` | the cone-stack pine near the high line | 32 | `pine_cone` 64 x 64 | |
| `rock-a`, `rock-b`, `rock-c` | rock outcrops | 60 to 120 | `rock` | |
| `fence` | snow fence, crowd fence | 12 each | cut-out textures | |
| `cannon` | the confetti cannon | 40 | a 64 x 64 page | |

Gates: the pipeline's (blockout, concept volume gate, final outline and
fidelity gates, the fidelity sheet rendered through the PSX frame) and
`psx_audit.py model <final> --max-tris <budget>`.

## 3. Textures (the raster track, fitted with psx_texture.py)

Every texture is generated at 1024 from psx-style's PSX texture brief
(its prompts.md), fitted with `psx_texture.py`, imported lossless without
mipmaps, and passes `psx_audit.py texture`.

| Texture | Size | Colours | Alpha | Tiles |
|---|---|---|---|---|
| `snow_groomed`, `snow_powder`, `snow_packed` | 64 x 64 | 16 | no | yes |
| `ice` | 64 x 64 | 16 | no | yes |
| `rock`, `bark`, `box`, `pine_cone` | 64 x 64 | 16 | no | yes |
| `pine_a`, `pine_b` | 64 x 128 | 16 | 1-bit | no |
| `crowd` | 128 x 64 (4 variants) | 16 | 1-bit | no |
| `fence_snow`, `fence_crowd`, `flag` | 64 x 32 | 16 | 1-bit | horizontally |
| `neon` | 64 x 16 | 16 | no | horizontally |
| `chrome_matcap` | 64 x 64 | 32 | no | no |
| `mountains` | 256 x 64 | 16 | 1-bit | horizontally |
| `banner_frostbyte`, `banner_neonpeak`, `banner_avalanche`, `banner_chillwave`, `banner_pow`, `banner_radical` | 128 x 64 | 256 | no | no |
| `arch_start`, `arch_split`, `arch_finish` | 128 x 128 | 256 | no | no |
| `board_base` | 64 x 128 | 256 | no | no |
| `fx_puff` (4 frames), `fx_spark` (2), `fx_star` (2), `fx_confetti` (2 x 4 colours), `fx_flare` (4 shapes), `fx_speedline` | 64 x 16 to 128 x 32 | 16 | 1-bit | no |

The sponsors are fictional (LOOK.md, section 8); every generated texture
with lettering is checked by the person for invented real brands.

## 4. 2D components (the 2D track)

Drawn as RML on the 320 x 240 grid (RIVE.md, section 7), each through
graphic-draft (its states on one sheet), graphic-concept (painted in the
1998 style) and graphic-final (RML with its view model and machine, or
raster exports at their 1x size where a chrome or painted look is needed).

| Component | States |
|---|---|
| `TrickBanner` | live, slam, hold, out; reduced motion |
| `Praise` | the nine words (NICE to BAIL) |
| `ComboMeter` | inactive, active, bump |
| `BalanceMeter` | centred, leaning, danger |
| `Countdown` | 3, 2, 1, GO, READY |
| `GradeStamp` | S, A, B, C (raster letters, chrome, 64 x 64 at 1x) |
| `TallyRow`, `ScoreRow` | counting, done, new record |
| `Glyph` | each button and key used, pad and keyboard |
| `MenuItem` | rest, focus, pressed, disabled; the volume bar's 11 steps |
| `Logo2D` | the logo at 1x for the pause and the results (raster) |
| `PressStart` | on, off (the blink) |
| `Wipe` | the snow wipe's frames |

## 5. Sounds

None as files: every sound is synthesised (AUDIO.md). The exceptions:

- the announcer's **voice bank**, only if the formant voice fails its
  intelligibility gate (AUDIO.md, section 7): about 70 recorded words,
  22,050 Hz mono, 1.5 MB, recorded by a person under a release the person
  approves;
- the **degraded tier**'s renders for a threadless web page (AUDIO.md,
  section 10): rendered by the game's own processor, about 3 MB, in that
  build only.

## 6. Fonts

Two faces, embeddable under the SIL Open Font License, chosen at A0 from
these candidates (each checked for its licence file before it is added to
`fonts/`):

| Role | Candidates | Why |
|---|---|---|
| Display (trick names, praise, the grade, menus) | Exo 2 Black Italic, Russo One (slanted in RML), Audiowide | wide, heavy, techno, italic: the brief's "wide, italic, techno-style" |
| Pixel (numbers, labels, the timer) | Silkscreen, Press Start 2P, Pixelify Sans | a pixel grid that holds at whole multiples on the 320 x 240 grid |

## 7. Budgets in one table

| What | Budget |
|---|---|
| A frame's visible triangles | under 20,000 (PERF.md) |
| The rider | 480 triangles, one 128 page and a 64 x 128 |
| Any one prop | its class's budget (section 2), never above 600 |
| Textures | about 60, all lossless RGBA8 without mipmaps: 64 x 64 is 16 KB of GPU memory, 128 x 128 is 64 KB; under 3 MB in all |
| Composed shaders | the 7 of psx-style plus the lake's lit variant: 8, about 6.5 MB of the `.riv` |
| The `.riv` | PERF.md, section 4 |

## 8. Approvals

Grouped into the person's review sittings:

| Sitting | Milestone | What is shown |
|---|---|---|
| 1 | A0 | every model's blockout and PSX concept, every texture's generation, every 2D component's draft and concept: the three index sheets and the look lab's frame (`psx_frame` with three concepts' colours) |
| 2 | A1 | the rider's final (it is needed in the lab) |
| 3 | A6 | every other final, the three index sheets of finals, the eight reference shots |
| 4 | A5 | the music and the announcer (renders, the intelligibility results) |

A milestone's done-when includes `asset.py status` passing for every
asset it delivers and `psx_audit.py` passing for every file it ships.
