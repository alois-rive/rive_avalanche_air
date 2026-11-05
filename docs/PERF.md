# Performance budgets

The PSX look is cheap to draw: the world is 76,800 pixels, unshaded, with
no engine lights and no shadow maps. The budgets that bind are the CPU's
(physics, the scene tree, the pins, the draw recording, all on the main
lane on a threadless web page) and the download.

## 1. Platforms and targets

| Platform | Target | Reference machine |
|---|---|---|
| Desktop native (the previewer or the Hedra shell) | 60 fps, frames under 16.7 ms at the 99th percentile | an Apple M2 Air; an Intel Iris Xe laptop at 60 fps too |
| Web, threaded build (WebGL 2, cross-origin isolated) | 60 fps at the 95th percentile, 1280 x 720 window | the same M2 Air in Chrome and Safari |
| Web, threadless build | 60 fps; the degraded audio tier | the same |

## 2. The frame (web, 16.7 ms)

| Part | CPU (ms) | GPU (ms) |
|---|---|---|
| The rider's ticks (2 a frame at 120 Hz: mover, probes, flight solve, grind) and the Box3D step | 0.40 | |
| Tricks, camera, autopilot or input, the sun's schedule | 0.15 | |
| Particles (at most 600 live) | 0.50 | |
| The scene tree, the pins, the `Daylight` timeline, the Rive HUD | 0.80 | |
| `sound.as` (knobs and cues) | 0.05 | |
| Draw recording (at most 120 draws) | 1.20 | |
| The SubViewport's pass at 320 x 240 | | 0.6 |
| The present quad at the window's size | | 0.2 |
| The Rive HUD | 0.40 | 0.3 |
| **Total** | **about 3.5** | **about 1.1** |

The audio processor runs on the audio thread (AUDIO.md, section 11), not
in this frame.

## 3. Counts

| What | Budget | Why |
|---|---|---|
| Draws | 120 | the course's tiles in view (about 12), features (30), dressing and props (35), the trees' two MultiMeshes, the rider's 16 parts, the blob shadow, the trail (section 5), the sky, particles' emitters (up to 8), the present quad |
| Visible triangles | 20,000 | psx-style's frame budget (4x a PlayStation) |
| Engine lights | 0 drawn | every PSX surface is unshaded and lit in its vertex stage |
| Shadow maps | none | blob shadow only |
| Particles live | 600 | spray 48, bursts 48, speed lines 24, flakes 150, sparks 12, confetti 240, the flare's 5 |
| SubViewports | 1 | the frame |
| Decals | 0 | they do not paint unshaded surfaces |
| Composed shaders | 8 | psx-style's 7 and the lake's lit variant |
| Sounds | 0 runtime sounds (the processor mixes everything); the degraded tier: at most 24 | |

`hedra inspect world/run.rscn --stats --camera <cam>` at the eight
reference views (TESTS.md, case 7) holds draws and triangles to these.

## 4. Memory and download

| What | Budget |
|---|---|
| The `.riv` | 12 MB, 5 MB gzipped (8 shaders about 6.5 MB, box3d-as about 1 MB, the engine, the course's meshes, textures under 3 MB, fonts) |
| The degraded tier's sounds | 3 MB more, threadless build only |
| The voice bank (only if used) | 1.5 MB |
| GPU memory | under 64 MB: textures under 3 MB, the 320 x 240 targets, the window's |
| Wasm heap | under 1,024 pages (64 MB) after load; 0 pages of growth a frame; flat over ten runs |
| First frame | under 3 s on the web from a warm cache |
| Restart | the rider's control back within 60 frames (1.0 s) of the press; at most 120 (TESTS.md, case 5) |

`hedra.yaml` sets `export/embed_sources: false` (the kart's finding: a
scene's sources embedded beside its built form multiplied its `.riv`).

## 5. The board trail

96 segments drawn as one `MultiMesh` once scripts can write its
transforms (E-MULTI, SPEC.md, section 13); until then 24 segments of 1 m,
each a `MeshInstance3D` moved by script (24 draws, inside the budget),
fading after 3 s.

## 6. What to measure, and how

```sh
hedra inspect world/run.rscn --stats --camera Course/Cameras/RefK3 --size 320 240
rive . --bench=600 --data=data/demo=true                      # advance and draw times, heap pages
rive . --bench=600 --data=data/demo=true --job-threads=1      # the web's single lane, natively
rive . --render-audio=shots/run.wav --advance=96s --release   # the processor's block times in the log
```

The benchmark tests run alone on a quiet machine (`--bench` in the test
runner, as the Hedra repository's `tools/test-everything.sh --bench`).
