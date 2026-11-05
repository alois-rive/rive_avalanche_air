# Briefs for the image generator, in the PSX style

These extend image-generate's templates (`image-generate/references/prompts.md`):
the same order (what to keep, what to paint, what not to do), the same
sizes, the same checks. What changes is the style block, which every PSX
brief carries word for word, so that every generation of a project agrees.

## The style block

```markdown
Style: a 3D render from a 1998 Sony PlayStation game, as a screenshot of
the time shows it: low-polygon models with visible flat facets and hard
edges, chunky simplified proportions, small pixelly textures (each texel
visible, painted, few colours, no fine noise), soft vertex lighting with
no cast shadows, colours slightly muted with a few saturated accents
(<the project's accents as hex, e.g. hot pink #f83890, acid green #a8f830,
orange #f88818>). Detail is painted into the textures, not modelled. Not
modern: no smooth subdivided surfaces, no bevels, no realistic materials,
no soft shadows, no ambient occlusion, no depth of field, no film grain.
```

## 3D: a concept over a blockout sheet

image-generate's template "3D: a concept over a blockout sheet", with:

- under "Design and paint, freely": the real object, simplified the
  PlayStation way ("a snowboarder in a baggy hooded jacket and wide
  trousers, goggles on a beanie, chunky gloves and boots; built from about
  15 rigid low-poly segments, the joints visible"), a line per part with
  its colour (15-bit hex), then **the style block**;
- the light line kept ("even, neutral light from the upper left"): the
  concept's colours become the texture's;
- under "Do not": "no smooth organic surfaces, no subdivision, no more
  detail in the geometry than the silhouette needs".

The fidelity gate later compares this sheet with the final rendered
through the PSX frame, so the concept must already look like that render.

## 3D: a PSX base texture

```markdown
A seamless, tileable square texture of <material: "packed snow on a groomed
ski run, with soft corduroy grooming lines and a few wind-blown ridges">,
1024 x 1024, seen straight on, filling the frame edge to edge, painted
for a 1998 PlayStation game: it will be shown at 64 x 64 texels in 16
colours, so paint it as big, simple, readable shapes (features of
<1/8 to 1/4> of the square), 3 to 5 values, crisp edges between them, no
fine noise, no photographic detail.

Albedo with a little painted top light allowed; no strong highlights, no
cast shadows, no perspective, no vignette, no border, no text.
Colours: base <#rrggbb>, between <#rrggbb> and <#rrggbb> (15-bit values).
The left edge continues seamlessly into the right and the top into the
bottom.
```

Then `psx_texture.py --size 64x64 --colors 16 --tileable` (textures.md).

## Raster: a tree, a sprite sheet, a sky strip

```markdown
<What: "A snow-laden pine tree for a crossed-quad billboard">, drawn as a
texture for a 1998 PlayStation game: it will be shown at <64 x 128> texels
in 16 colours with 1-bit transparency, so paint big, simple shapes with
crisp edges, few colours, no soft gradients at the outline.
Composition: <the tree centred, its trunk's base at the bottom edge, its
tip near the top, filling the height>.
Background: flat uniform #808080, nothing else drawn (it will be cut out).
Palette: <#rrggbb, ...>.
Do not add a ground, a shadow, text or a frame.
```

A sprite sheet: "<N> frames in one row, each in an equal square cell,
<the animation: a puff of snow growing and breaking up>", then fit with
`psx_texture.py --size 64x16 --colors 16 --key-bg --mode contain`.

## Raster: a UI piece (logo, grade stamp, banner)

```markdown
<What: "The letter S as a grade stamp for a 1998 extreme-sports game's
results screen">, 1024 x 1024: chrome lettering with a sky-blue to
sunset-orange reflection band and a hard dark horizon line through it, a
thick black outline, a hard drop shadow offset down-right, wide heavy
italic techno letterforms, <the accent>. Flat uniform #808080 background.
It will be shown at <64 x 64> pixels with at most 32 colours: big shapes,
crisp edges, no fine texture.
Do not add other text, a frame or a signature.
```

Fit with `raster_fit.py --colors 32` at its 1x size on the 320 x 240 grid.

## Reviewing a PSX generation

Beyond image-generate's checks and the stage's gate, look for:

- **Modern leakage**: smooth subdivided forms, realistic fabric folds,
  soft shadows, depth of field: brief again with the style block first.
- **Detail too fine**: features smaller than 1/32 of the image will not
  survive 64 texels; brief bigger shapes.
- **Text**: a generator's invented logos and lettering; the person decides
  whether any ships (image-generate, "Review").
