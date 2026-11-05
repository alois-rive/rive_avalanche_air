# hedra_engine

The library that draws 3D scenes in Rive: the Hedra engine as
AnimaScript source and WGSL shaders, the public modules scripts and host
code import, and the readers that draw a scene from its sources. Every
tool of this repository renders with these files, and the CLI's `build`
copies this directory as it is into a Rive project, as `hedra_engine/` beside
`rive.yaml`, so a scene drawn in Rive is drawn as the editor draws it. The
guide is [docs/cli/BUILD.md](../../docs/cli/BUILD.md).

## The rule

A copy works anywhere in a Rive project because a file here imports only
the rive std (`rive/...`) and the files of this directory, by relative
paths (`../base/util`), and the directory holds only `.as` and `.wgsl`
files, `hedra_engine.rml` at its top and this README, save the copy of
Box3D in `physics/box3d/`, which also holds upstream's `LICENSE`, its
note `UPSTREAM.md` and `SHA256SUMS` (below). In the repository,
everything else imports it as `hedra_engine/...`; it never imports
them. `python3 tools/check_engine.py` checks the rule (`--list`
prints the files, `--json` the import graph); the tools suite and CI run
it. Its test, `tools/check_engine_test.py`, also copies the
directory into a bare Rive project (a Layout that makes the run time, and
the library's own `Scene3D`) and bakes it with the pinned rive, once whole
and once with `hedra_engine/source` excluded: rive compiles every `.as` it
finds, so every file here compiles with nothing else beside it.

## The three parts

| Part | Files | What it is |
|---|---|---|
| public | `script.as`, `scene.as`, `scene3d.as`, `hedra_engine.rml` | what scripts, host code and RML name; a name that leaves bumps the major version |
| engine | `base/`, `host/`, `io/`, `material/`, `meshproc/`, `physics/`, `render/`, `engine/src/scene/`, `shaders/`, `texture/`, `version.as` | the run time: scenes, nodes, scripts, bindings, the renderer, and the physics library |
| source | `source/` | the source readers: glTF with its Draco and meshopt decoders, `.rmdl` (a model's document, read without the command kernel), `.rmdlcmd` (a model's commands: the model kernel's replay of data-form models, or a cache entry), MaterialX |

Only `source/` imports `source/`. 599 files: 4 public, 382 engine and
213 source (3.1 MB of the 11.7 MB). The bare project of these files bakes to
a 7.8 MB `.riv`, 6.5 MB without `source/`, and 9.1 MB with the commands
tier (`commands/`) beside them (`tools/check_engine_test.py` bakes each).

`physics/box3d/` is [box3d-as](https://github.com/luigi-rosso/box3d-as),
Luigi Rosso's port to AnimaScript of Erin Catto's Box3D, byte for byte as
it is upstream (MIT: its `LICENSE`; the commit and how to move it:
`UPSTREAM.md`), 61 of the engine's files and 1.8 MB. It imports only
itself and the rive std (`rive/parallel` among them, which only a rive
with parallel calls has), only `physics/` may import it, and nothing does
yet; since rive compiles every `.as` file it finds, it is in each bake
above (about 0.6 MB of each). `python3 tools/check_box3d.py` checks the
copy against its `SHA256SUMS` (`--upstream <checkout>` against a box3d-as
checkout, `--sync <checkout>` makes a new copy). Its own lint warnings
are upstream's, and the checks of the library's warnings leave them out.

### The public modules

- **`hedra_engine/script`**: the node script API. `NodeScript`, the node
  classes (`SceneNode` and the Node3D API, `Camera3D`, `Light3D`,
  `Path3D`, `PathFollow3D`, ...), `Curve3D` and the `ROTATION_*` modes,
  `InputEvent`, `PackedSceneRef`, `SignalEvent`, `Value` and `ValueKind`,
  `Vec2`, `Vec3`, `Vec4`, `Quat`, `Timer`, `Tween`, `EaseType`,
  `TransitionType`, `print`, `printErr`, `pushError`, `pushWarning`, the
  scene's timelines (`ScriptScene`, `ScriptAnimation`), and the registry
  types a generated `hedra_project.as` uses (`ScriptRegistry`,
  `ScriptFactory`, `ScriptSetter`).

  ```ts
  import { NodeScript } from "hedra_engine/script";

  export class Spin extends NodeScript {
      speed: f32 = 0.5;
      override process(delta: f32): void {
          this.node.rotateY(this.speed * delta);
      }
  }
  ```

  `this.scene` is the scene that declared the script's node (its `.rscn`,
  the root scene or one it instances; null where nothing plays the tree,
  as in the tools). `scene.animation(name)` is one of its timelines, the
  same object on every call, with Rive's script `Animation` API
  (`advance(seconds)`, `setTime(seconds)`, `setTimeFrames(frames)`,
  `setTimePercentage(fraction)`, `time()`, `duration`) and two verbs of
  its own: `play()` has the run time advance it every frame, after the
  bindings' pull and before the scripts, until `stop()` or a oneShot's
  end; `mix` (0 to 1) is how strongly it writes over the values there, in
  the order the animations were played. `advance` and `setTime*` apply at
  once. `animationNames()` lists them; `fireEvent(name)` fires the scene's
  `Event`, as a timeline's key on `event:<name>` does: the scene's root
  emits `event_fired` with the name, which `<connection>`s, scripts and a
  `signal:event_fired` binding hear.

  ```ts
  export class Door extends NodeScript {
      override ready(): void {
          const open = this.scene!.animation("Open");
          if (open != null) open.play();
      }
  }
  ```

  `scene.stateMachine(name)` is one of the scene's state machines, the
  same object on every call: `input(name)` is one of its inputs
  (`number()`, `setNumber(v)`, `boolean()`, `setBoolean(b)`, `fire()` for a
  trigger, seen by the next advance), `currentStates()` lists each layer's
  state (`"Door/Open"`), `isPlaying()` says whether the scene runs it,
  `play()` runs it from its start in place of the one the scene ran and
  `stop()` runs none. `stateMachineNames()` lists them;
  `scene.bindViewModel(vm)` and `scene.bindGlobal(name, vm)` bind the
  running scene's data as the host's `SceneInstance` does.

  ```ts
  const main = this.scene!.stateMachine("Main");
  const knock = main != null ? main.input("knock") : null;
  if (knock != null) knock.fire();
  ```

- **`hedra_engine/scene`**: the run time for host code. `newSceneRuntime()`
  (a `SceneRuntime` with every feature installed, its shaders found under
  `hedra_engine/`), `SceneRuntime.load`, `loadText`, `loadBuilt`, `builtState`
  and `loadFrom`/`builtStateFrom` over any `FileSource`; `SceneOptions`
  (`source`, `unbuiltLabel`, `project`), `SceneLoad` (`instance`, `source`,
  `reason`, `errors`, `scenePath`, `label`), `SceneSource` (`Auto`, `Text`,
  `Built`), `BuiltState` (`Current`, `Missing`, `Stale`, `OtherMajor`,
  `Invalid`), the `REASON_*` texts, `BlobFiles`, `registerProject`,
  `projectNamed`, `registeredProjects`, `SceneInstance` and its handles,
  the events a scene fires (`FiredEvent`, `EVENT_FIRED_SIGNAL`),
  the label (`UnbuiltLabel`, `labelText`, `labelFit`, `labelRect`), and the
  version (`HEDRA_ENGINE_VERSION`, `HEDRA_ENGINE_MAJOR`, `HEDRA_ENGINE_DIR`).

  A `SceneInstance` takes its data as an artboard does:
  `bindViewModel(vm)` binds the scene's own view model instance (Rive's
  `bindViewModelInstance`), and `bindGlobal(name, vm)` puts a view model
  of the host's in place of the global called `name` (`null`: the
  Context's again). `playAnimation(name)` plays the root scene's timeline
  `name` from its start in place of the last one played so (`""` stops
  it), `playStateMachine(name)` runs the root scene's state machine `name`
  from its start in place of the one it ran (`""` its default, `-` none;
  the scene runs its default without being asked), and `takeEvents()` gives the events the scene fired since the last
  call (`FiredEvent`: `scene`, `name`, `delay`, `decl`), for a host that
  polls them; a host that never does calls `dropEvents()` each frame,
  which forgets them and keeps them for the next ones, allocating nothing
  (the Scene3D component does, before each advance). Otherwise a binding written `global="Theme"` finds the
  global in the host's `Context` (`Context.globalViewModel`), looked up
  from the first advance and given up after 60 advances with one error in
  the status. `registerProject`'s fifth argument, `dataFiles`, lists the
  Rive project's `.rml` files its scenes take data from (the generated
  `hedra_project.as` passes it); `newSceneRuntime()` installs
  `BlobProjectData` (`engine/src/scene/runtime/project_data.as`), which reads those
  files through the project's blobs, once per project, so a scene drawn
  from its text resolves the view models, globals and converters a built
  scene carries in its data section. It also installs the remaps (each
  resource read from its built form when one is current) and the one
  resource cache every runtime it makes shares, with its lifetimes and
  the CPU copies released after upload
  ([RESOURCES.md](../../docs/engine/RESOURCES.md)); a runtime made with
  `new SceneRuntime()` has neither and keeps what it loads for its life.

  ```ts
  import { SceneOptions, newSceneRuntime } from "hedra_engine/scene";

  const rt = newSceneRuntime();
  const got = rt.load(context, "world/courtyard.rscn", new SceneOptions());
  const scene = got.instance;      // null when nothing could be drawn
  // each frame: scene.advance(seconds); scene.draw(renderer, width, height, scale)
  ```

- **`hedra_engine/scene3d`**: the `Scene3D` component, the only `Layout` of the
  library. A `ScriptedLayout` with `scriptAssetId="93:1"`, bound to a view
  model with the properties `scene`, `source`, `unbuiltLabel`, `camera`,
  `playing`, `speed`, `yaw`, `lodThreshold`, `animation` (the scene's
  timeline to play, `""` none), `stateMachine` (the scene's state machine
  to run, `""` its default, `-` none), `data`, `status` and `events` (the
  events the scene fired since the last advance, one name a line); its
  inputs `artboard_0` to `artboard_7` take the scene's artboard textures in
  the scene's order. Each scene it shows is loaded into a runtime of its
  own.

- **`hedra_engine.rml`**: the library's declarations, the same in every
  project, ids of client 93: the `ScriptAsset` of `scene3d.as` (`93:1`) and
  the `Scene3D` view model (`93:10`, its default instance `93:11`, its
  properties `93:12` to `93:27`).

## Three sources

A scene in a Rive project is drawn from one of three sources
(`engine/src/scene/runtime/sources.as`, `engine/src/scene/runtime/scene_runtime.as`):

- **Text**: the `.rscn` and its original files, read at run time through
  the `hedra:<path>` blobs the Hedra project's `hedra_engine.rml` declares.
  The run time puts them in its virtual file system under
  `/hedra/<project>` through a read fallback (`host/vfs.as`
  `Vfs.setReadFallback`), so the loader reads the scene exactly as the
  editor does; a script's `.as`, never declared, is answered with a line
  naming the class the project registers, and an undeclared
  `hedra.yaml` with an empty one.
- **Built**: the scene's `.rscnb` under `build/hedra/`, through its
  declared blob: one decode, prebuilt meshes, compressed textures. Its
  `SRCS` section (`engine/src/scene/rscnb/srcs.as`) records the library major it
  was built for and the SHA-256 of the text it was built from. A scene a
  script loads that the built file does not carry is read from its
  declared text.
- **Auto**: Built when `builtState` says `Current`, else Text, with the
  reason and, when `unbuiltLabel` is on, the label
  (`engine/src/scene/runtime/label.as`): one line in the canvas's top-right corner,
  drawn with a stroked font of the library's own, its paths built once per
  text and size.

Scripts are found in the project's registry, filled by its generated
`hedra_project.as` (`registerProject`), keyed by each script's path in
the project in both sources. An idle scene allocates nothing per frame
from either source, its label shown or not.

## Hooks: what the tools install

Where the engine needs code only the tools or `source/` carry, it
declares an abstract class and they install theirs:

- `FileReaders` (`engine/src/scene/resource/loader.as`, `installFileReaders`): how
  the loader reads a model file and a MaterialX material file. The
  engine's own, `ExportedReaders`, fails each read naming why
  (`readsSources()` false: a scene drawn from its text then says `no
  source readers`). `source/install.as` installs the source readers by a
  top-level statement, so they are there whenever `source/` is compiled;
  the tools install the same at start.
- `ModelSource` (`engine/src/scene/resource/types.as`): the model a
  `ModelResource` was read from (`engine/src/source/scene/resource/model_source.as`
  wraps the model kernel's scene); a built scene's models have none, their
  meshes arrive prebuilt.
- `LodSource` (`engine/src/scene/render/meshes.as`): a mesh's levels of detail;
  the tools generate them, the run time reads the built scene's.
- `ResourceProvider` (`engine/src/scene/resource/provider.as`): ready resources the
  loader takes before it would read a file; the run time's is the built
  scene's (`engine/src/scene/bundle/provider.as`).

## Versions

`version.as` holds `HEDRA_ENGINE_VERSION` (0.1.0, the product version in
`VERSION` at the repository's root, restarted with Hedra) and its major.

## What is here

Each directory keeps the path it had under `shared/src/`.

```
version.as     the library's name and version
script.as      hedra_engine/script: the node script API
scene.as       hedra_engine/scene: the run time for host code
scene3d.as     hedra_engine/scene3d: the Scene3D component
hedra_engine.rml    the library's declarations (ids of client 93)
base/          the foundation: Result, util, fmt, parse, json, xml, vector
               math, libm, colours, errors, log, SHA-256, and a command's
               outcome (outcome.as: Answer, Failure, the exit codes), which
               the tools build and their hosts print, and the pool of
               scratch buffers the decoders and uploads reuse (scratch.as)
host/          the virtual file system (vfs.as, its read fallbacks),
               path.as, base64.as
io/compress/   meshopt's decoders (a prebuilt mesh's compressed vertices)
material/      glTF's whole material (pbr.as)
meshproc/      a prebuilt mesh's vertex codec and level-of-detail bytes
texture/       the KTX2 reader and the BC, ETC2 and ASTC decoders
render/        the renderer: frames, cameras, materials, lights; what
               the GPU holds for the resources (gpu/ledger.as) and the
               uploads' events (upload_events.as)
               (light_pool.as: the budgets, 64 a frame and 8 an item, and
               what a view's choice holds; light_select.as: the view's
               pool and each item's 8), shadows,
               sky, post-processing, instancing, culling, the lightmap and
               probe data a frame draws, decals (decal.as: what a frame
               carries and the budgets; decal_select.as: the frame's pool
               of 64 and each item's 8), viewports (viewport.as: what a
               frame carries, the budgets and the schedule of update
               modes), fog volumes (fog_volume.as: what a frame carries,
               the budgets of 16 a frame and 4 an item; fog_select.as:
               the frame's pool, each item's list, each volume's lights
               and the CPU twin of the shader's integration), occlusion
               culling (occluder.as: what a frame carries; occlusion.as:
               the CPU depth buffer, its levels and Godot's test, which
               cull.as runs), the GPU side (gpu/: decals.as, the decal
               block and the atlas; viewports.as, the viewports' live
               targets; fog.as, the fog block; custom.as, a shader
               material's pipelines, its group of parameters and
               textures, and the views' groups of its module;
               screen_inputs.as, what the screen-space passes read;
               screen_chain.as, the screen texture and its levels;
               ssr.as, the reflections' march and merge; dof.as, the
               depth of field's passes), the screen-space effects
               (screen.as: what a frame carries of the reflections, the
               screen refraction and the depth of field, the project's
               quality and Godot's curves; ssr.as and dof.as: the CPU
               twins of the reflections' march and the blur's gather),
               custom
               shaders (shader/: a .wgsl file's reader (lex.as,
               parse.as) and its program (program.as: Godot's built-ins,
               render modes and hints, the limits), the parameters'
               block (layout.as), the hook the compiled modules come
               from (modules.as); custom_material.as: what a frame
               carries of a shader material), what a frame costs
               (quality.as: the project's render quality in Godot's
               names, MSAA, the rendering method, the depth prepass, the
               opaque sort, the specialisation and the render scale;
               scaling.as: the 3D's picture size under the scale and the
               density and pixel caps; variant.as and variant_keys.as: a
               surface shader variant's key and a draw's key from its
               own uniforms; shader/variants.as: the hook the variants'
               modules come from; probe_select.as: each item's
               reflection probes; on the GPU side gpu/variants.as, a
               key's pipelines, gpu/order.as, the opaque order,
               gpu/prepass.as, the depth prepass, gpu/fsr.as, FSR 1.0
               and the stretch, and gpu/shadow_cache.as, the shadow
               tiles kept from one frame to the next while their light
               and casters stay the same; SSAO traced at half size
               (post.as's flag, gpu/layouts.as's sizes):
               docs/engine/PERFORMANCE.md)
shaders/       the renderer's WGSL (shaders/render/*.wgsl; among them
               post_fsr.wgsl, FSR 1.0's EASU and RCAS and the bilinear
               stretch, and shadow_clear.wgsl, the far-plane triangle
               that clears a shadow tile drawn again)
engine/src/scene/       scenes: values and classdb, the .rscn document, reader and
               validator (rscn/), the XML documents' shared reading half
               (textdoc/: the root, ext_resource, properties and their
               positions, the id and path rules, which .rscn and .rmdl
               share), .rscnb and its SRCS section (rscnb/), the
               scene tree and instancing (tree/), resources and the loader
               (resource/; the run time's one resource cache in
               resource/cache.as, the CPU copies let go of after upload
               in resource/cpu_copy.as), the scene renderer (render/), view model
               binding (binding/: the targets, the binder and its data
               contexts, the converters (converters.as), the outputs
               (outputs.as), a scene's data for the tools (scene_data.as),
               the resources' bindable fields (material_fields.as)), Rive
               data (data/: the data model (model.as), where a scene's data
               comes from (source.as), the RML reader (rml_read.as)), the
               .rscnb data section (rscnb/binds.as), Rive's timelines
               (anim/: the declarations (decl.as) and their checks
               (check.as), the interpolators
               (interp.as), a compiled LinearAnimation (animation.as), its
               instance (instance.as), a scene's timelines on its nodes
               (scene_anims.as)) and their .rscnb section (rscnb/anim.as),
               Rive's state machines (sm/: the declarations (decl.as) and
               their checks (check.as), a compiled machine (machine.as),
               its instance (instance.as), how it reads the data
               (data.as, resolve.as), a scene's machines and the tools'
               sample (scene_machines.as), a tree's machines run as one
               (runner.as), their listeners (listeners.as), the pointer
               events a tool hands them (pointer_input.as) and the
               tools' scripted pointer (pointer_script.as)) and their
               .rscnb section (rscnb/sm.as), what a pointer hits for the
               listeners and the artboards shown in 3D (listen/pick.as),
               paths (path/: Godot's Curve3D (curve3d.as), its bake and
               sampling (bake.as) in Godot's 32-bit order (math.as), a
               PathFollow3D's placement (follow.as), the curves as lines
               (lines.as)), decals on a frame (render/decals.as),
               viewports (tree/viewports.as: the graph of SubViewports,
               their worlds, cameras and textures; render/viewports.as:
               their views on a frame), particles (particles/: Godot's
               CPUParticles3D simulated (sim.as, the shapes in emit.as,
               the hue in hue.as, a particle's random stream in
               random.as, its state in state.as, points from a mesh in
               points.as, the tools' clock in clock.as) and packed for
               the instanced draw (pack.as); render/particles.as: their
               draws on a frame; resource/curve.as and gradient.as:
               Godot's Curve and Gradient), spatial audio (audio/:
               Godot's AudioStreamPlayer3D attenuation and speaker
               model (attenuation.as), the listener (listener.as), a
               player's playbacks (state.as) and the scene's clock
               (clock.as), and the backend the run time plays through
               (backend.as, rive_out.as over rive/audio); the stream's
               resource in resource/audio_stream.as, the built scene's
               Audio entry in bundle/audio.as), fog volumes
               (render/fog_volumes.as: the volumes and the volumetric
               fog on a frame; resource/fog_material.as: the
               FogMaterial), the screen-space effects
               (render/screen.as: a frame's camera attributes and depth
               of field; resource/camera_attributes.as: Godot's
               CameraAttributesPractical), occluders (render/occluders.as: the
               occluders on a frame; render/occluder_shapes.as: Godot's
               shapes' triangles; resource/occluders.as: the Occluder3D
               resources; resource/occ_file.as: the .occ reader),
               shaders (resource/shader.as: the Shader of a .wgsl file
               and the ShaderMaterial, its parameters and fallback;
               runtime/shader_assets.as: the compiled modules a Rive
               project carries), navigation (navigation/: the scripts'
               API, Godot's NavigationServer3D map queries and path query
               objects (api.as), the map built from the regions and links
               and its sync (map.as), its spatial grid (grid.as), the A*
               over its polygons and the query scratch (astar.as), the
               corridor funnel, the edge-centred and the simplified paths
               (funnel.as), an agent's state and its update by Godot's
               rules (agent_state.as, agent.as), the RVO avoidance and its
               job (avoidance.as), a scene's step of the map, the agents
               and the obstacles (sim.as), the tools' clock (clock.as),
               Visible Navigation's lines (lines.as) and the project's
               settings (settings.as); resource/navigation_mesh.as: the
               NavigationMesh), .riv
               reading (riv/), the NodeScript API
               (script.as, script/: a script's scene, scene_api.as), .lmbake and .rprobe, the built
               scene's asset container reader (bundle/), the player's artboards and
               view model (player/), the run time (runtime/: SceneRuntime
               and the three sources, the projects' registry and their
               data (project_data.as), the label, the features (the
               timelines': feature_animation.as, events.as; the
               particles': feature_particles.as; the sounds':
               feature_audio.as; the navigation's:
               feature_navigation.as), the surface shader variants a
               built project carries (variant_assets.as), the hooks a
               run time's resources are managed by (runtime_hooks.as:
               the remaps to the built forms, remap.as, and the
               resource cache's lifetimes, runtime_resources.as), the
               loading and memory settings (resource_settings.as), a
               load over several frames (load_task.as), Scene3DView);
               the scene renderer's artboard_bits.as (each item's bits
               for the artboard textures it shows, which an update mode
               of when_visible reads) and lightmap.as (the lightmap's
               items, and the light from its probes kept per item and
               interpolated again only when the item moved)
source/        the source readers: Draco, glTF, the importers' core, the
               model files (model/formats.as tells them apart: an .rmdl
               document's reader, writer and validator in model/rmdl/,
               an .rmdlcmd's loader, cache and data form in
               model/rmdlcmd/; a model with the files it names put in,
               its instances and MaterialX materials, in model/compose.as),
               the XML documents' shared writer
               (textdoc/write.as), MaterialX, the model and material file
               readers, the sounds' readers (audio/: a WAV's, MP3's or
               FLAC's header in info.as, its .import's loop and forms in
               reader.as) (install.as installs them), and a project's
               settings and checks (project/: the screen-space effects'
               quality from hedra.yaml in screen_settings.as, their
               warnings in screen_warnings.as; the navigation map's
               settings from hedra.yaml in navigation_settings.as, the
               regions' and links' warnings in navigation_warnings.as,
               the agents' and obstacles' in
               navigation_agent_warnings.as; the render quality's
               rendering/* lines from hedra.yaml in render_settings.as)
```

## What is not here

Only the tools run these: the model kernel's commands (the replay of an
`.rmdlcmd` of commands, the editing of either model file) and the model
editor, the `.rscn` writer, the texture encoders, the mesh simplifier, the
lightmap baker and probe capture, the importers' caches, and the built
scene's writer.

The engine never writes a built form (HEDRA.md section 3.4). The writers
of built formats live in the compiler (`hedra_compiler/`): the `.rscnb`
writer and its section writers (`codec/rscnb_*write.as`), a scene file's
bytes for a path (`codec/scene_file_write.as`), the vertex, index and LOD
encoders (`codec/{vertex_codec,lod_bytes}_write.as`), meshopt's encoders
(`codec/meshopt/`), the KTX2 and Radiance HDR writers
(`codec/{ktx2,hdr}_write.as`), Draco's encoder (`codec/draco/`), the
bundle payload's writers (`bundle/payload_write.as`), `.lmbake` and
`.rprobe` (`bake/{lmbake,rprobe}_write.as`) and the replay cache's entry
(`model/cache_write.as`). Each keeps the bytes it wrote here. The PNG and
zlib encoders, which screenshots need as well, are in the source tier
(`source/codec/png_write.as`, `encodeImagePng` for an `Image`).

Kept here because they do not separate cleanly: Draco's shared classes
that hold an encoder's and a decoder's methods together (the prediction
schemes and their transforms, the attribute transforms, `metadata`), and
the encoder pieces they call (`core/encoder_buffer`,
`geometry/{encoder_options,compression_config}`,
`entropy/{rans_bit_encoder,shannon_entropy}`,
`prediction/*_encoding_transform`), plus the bit writers of
`engine/src/scene/rscnb/bin.as` that the payload readers share.
