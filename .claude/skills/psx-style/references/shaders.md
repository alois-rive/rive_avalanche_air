# The shaders

Seven WGSL files in `assets/shaders/`, each a Hedra `shader_type spatial`
shader (docs/engine/SHADERS.md of the Hedra repository has the format).
All are checked with `hedra check` and drawn together in
`images/psx_showcase.png` (hedra 0.1.0). Copy the folder into the project
(`world/psx/`), and `exclude:` it in `rive.yaml` as every `.wgsl` folder
must be (`build-shader-scanned`).

| Shader | For | Render modes |
|---|---|---|
| `psx_surface.wgsl` | every opaque mesh: terrain, props, buildings, character parts | `skip_vertex_transform, unshaded, cull_back, specular_disabled, shadows_disabled` |
| `psx_cutout.wgsl` | crossed-quad trees, fences, railings, banners with holes | as psx_surface, `cull_disabled`, 1-bit alpha |
| `psx_chrome.wgsl` | chrome letters, metal rails, goggles, a title logo | as psx_surface; a sphere map per vertex |
| `psx_sky.wgsl` | the sky: an inverted sphere centred on the lens | `world_vertex_coords, unshaded, cull_front, depth_draw_never, fog_disabled` |
| `psx_blob_shadow.wgsl` | the disc under a character | `blend_mul, unshaded, depth_draw_never, fog_disabled` |
| `psx_sprite.wgsl` | CPUParticles3D sprites with a flipbook | `skip_vertex_transform, unshaded, cull_disabled`, 1-bit alpha |
| `psx_present.wgsl` | the full-screen quad of the frame rig | `unshaded, fog_disabled, depth_test_disabled, depth_draw_never` |

## Assigning them

In a scene:

```xml
<ext_resource id="1_surface" type="Shader" path="psx/psx_surface.wgsl"/>
<ext_resource id="2_snow" type="Texture2D" path="textures/snow.png"/>
<sub_resource id="Mat_snow" type="ShaderMaterial">
  <property name="shader">ExtResource("1_surface")</property>
  <property name="shader_parameter/albedo_texture">ExtResource("2_snow")</property>
  <property name="shader_parameter/uv_scale">Vector2(16, 16)</property>
  <property name="shader_parameter/sun_direction">Vector3(-0.5, 0.35, -0.8)</property>
</sub_resource>
```

In a model (`.rmdl`), a material carries the shader and its parameters;
its own colour is the fallback a tool draws when the shader cannot be read:

```xml
<property name="shader">ExtResource("3_surface")</property>
<property name="shader_parameter/albedo_texture">ExtResource("4_jacket")</property>
```

On a MultiMesh or a CPUParticles3D the shader goes on the mesh's
`material`, not `material_override`. `render_priority` 1 on the blob
shadow's material draws it after the ground.

**Share one shader file.** Each composed shader adds about 0.8 MB to the
`.riv`; seven shaders used by a hundred materials cost seven composes. A
variant is a parameter, not a copy.

## psx_surface

| Parameter | Default | Meaning |
|---|---|---|
| `albedo_texture` | white | the PSX texture (nearest, repeating) |
| `albedo` | white | a tint, multiplied: palette swaps, colour schemes |
| `uv_scale`, `uv_offset` | 1, 0 | tiling; one UV unit a metre and `uv_scale` repeats a metre for terrain |
| `uv_scroll` | 0 | UV units a second: flags, water, a conveyor, a scrolling sign |
| `snap_resolution` | 320 x 240 | the jitter's grid; half for a cruder wobble; 0 off (a HUD prop in the world that must read) |
| `affine_strength` | 1 | 1 the screen-linear warp, 0 perspective-correct |
| `affine_near` | 1 m | vertices nearer the lens fade to perspective-correct (a triangle crossing the lens's plane has no affine UV) |
| `sun_direction` | (0.4, 0.6, 0.5) | towards the sun, scene frame (Y up) |
| `sun_color` | warm white | |
| `sky_ambient`, `ground_ambient` | blue-grey | the hemisphere: faces up get the sky's, faces down the ground's (on snow, a bright bounce) |
| `light_bands` | 0 | 0 smooth Gouraud; 2 to 8 stepped light (cel-like, an option the era had in some games) |
| `emission` | 0 | added after the light: lit windows, neon, the sun's disc on a sign |
| `overbright` | 1 | up to 2: the PlayStation's 2x modulation, highlights past white for the glow |
| `screen_door` | 0 | 0.25, 0.5, 0.75: that share of a 2 x 2 pattern of low-resolution pixels left out (`discard`): the era's translucency for a ghost or a respawn blink, still opaque, never sorted |

**Why view space, not POSITION.** Writing `POSITION` takes over the
projection and the shadow and depth passes would draw the camera's
projection into their atlases; snapping in view space under
`skip_vertex_transform` (project, round, unproject, write `VERTEX`) keeps
every pass consistent. Under `skip_vertex_transform` `VERTEX` and `NORMAL`
arrive in model space and must leave in view space (measured; SHADERS.md's
wording suggests otherwise).

**Why the frame turn.** The shader's world is Z up: `MODEL_NORMAL_MATRIX *
NORMAL` of a face pointing up in the scene is (0, 0, 1). `scene_to_frame`
turns a Y-up vector (x, y, z) into (x, -z, y), so `sun_direction` is
written as the scene's light is.

**Why `unshaded`.** The light is the shader's (Gouraud), so the engine's
per-pixel light is off. The engine's depth fog still applies, and the
present pass dithers what comes out. An unshaded surface takes no Decal
and casts no shadow (both PSX-correct).

**Large polygons.** The affine warp is proportional to a polygon's size on
screen. Ground and walls near the play area are tessellated to 1 to 2 m
triangles; far geometry can be coarse (models.md, "Subdivide for the
warp").

## psx_cutout

psx_surface plus `alpha_cut` (0.5): texels under it are not drawn. Both
faces drawn (`cull_disabled`), so one quad is a tree from both sides.

## psx_chrome

`matcap` (a 64 x 64 sphere map: sky band, dark horizon line, warm ground,
one hot highlight), `tint`, `albedo_texture` (what shows under it) and
`reflectivity` (0 to 1). The lookup is per vertex, so the reflection
swims across large faces exactly as the PlayStation's did; give chrome
letters enough vertices (bevel segments) that it moves.

## psx_sky

A gradient from `horizon` to `zenith` in `bands` steps, bent by `curve`;
`below` under the horizon; a sun disc (`sun_size`, degrees) and halo
(`halo_size`, `halo_strength`) towards `sun_direction` (Y up); and a
`horizon_texture` strip (mountains, a skyline; 1-bit alpha) wrapped
`horizon_repeat` times round the horizon between the elevations
`horizon_band` (degrees). Put it on a `SphereMesh` of radius 300 to 500
(24 x 12 segments) whose position a script sets to the lens's each frame.
Keep `horizon` equal to the Environment's `fog_light_color`.

Time of day is the sky's and the surfaces' uniforms keyed together (a
timeline), or written by one script to every material: zenith, horizon,
sun colour and direction, the ambients and the fog colour.

## psx_blob_shadow

A `PlaneMesh` (1 to 2 m) a few centimetres above the ground under its
owner, tilted to the ground's normal by the owner's script (a ray down).
`shadow_color` (a blue-grey on snow, never black), `rings` (hard steps of
the disc), `lift` (0 grounded to 1 high: the disc shrinks and fades; the
script writes it from the height above the ground).

## psx_sprite

For a `CPUParticles3D` whose mesh is a 1 x 1 `QuadMesh` with this
material. The quad is turned to the camera in the vertex stage (a
ShaderMaterial is not turned by `billboard_mode`), its size the particle's
scale. The flipbook: `sprite_sheet` holds `frames_x` x `frames_y` frames
left to right, top to bottom; the emitter's `color_ramp` must take alpha
from 1 at birth to 0 at death, and the frame is chosen from it (the age is
not otherwise visible to a shader). The ramp's RGB tints the sprite
(`COLOR.rgb` does reach a ShaderMaterial; the engine's
`particles-vertex-color` warning is a false positive here).

```xml
<sub_resource id="Ramp_age" type="Gradient">
  <property name="offsets">PackedFloat32Array(0, 1)</property>
  <property name="colors">PackedColorArray(1, 1, 1, 1, 1, 1, 1, 0)</property>
</sub_resource>
<node name="Spray" type="CPUParticles3D" parent="Rider/Board">
  <property name="amount">48</property>
  <property name="lifetime">0.6</property>
  <property name="mesh">SubResource("Mesh_puff")</property>
  <property name="color_ramp">SubResource("Ramp_age")</property>
  <property name="local_coords">false</property>
</node>
```

## psx_present

| Parameter | Default | Meaning |
|---|---|---|
| `screen` | | the SubViewport's `ViewportTexture` |
| `low_res` | 320 x 240 | the SubViewport's `size`; the dither grid |
| `color_bits` | 5 | bits a channel; 8 switches the quantisation off (for comparisons only) |
| `dither_strength` | 1 | the PlayStation's table at 1; 0 bands with no dither |
| `integer_scale` | 0 | 1 shows the picture at a whole multiple of 240 lines when the screen allows it |

The truncation keeps the PlayStation's range: white is 248 (#f8f8f8).
Values are quantised in display space (sRGB), the picture arriving and
leaving linear.

## Costs

- Vertex work: a projection, an unprojection and the light per vertex; on
  a scene of 20,000 triangles that is nothing.
- Pixel work: one or two texture reads per pixel at 76,800 pixels.
- The present pass: one quad, one texture read a screen pixel.
- `.riv` size: about 0.8 MB per composed shader: seven at most.
