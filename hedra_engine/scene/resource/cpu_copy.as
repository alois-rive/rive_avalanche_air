// CPU copies after upload (milestone 67b, docs/engine/RESOURCES.md, "CPU
// copies"): in a run time, a texture uploaded to the GPU keeps its handle
// and lets go of its decoded pixels (and of its compressed levels), as
// Godot's textures keep the RID and not the Image; a mesh whose GPU buffers
// exist lets go of its vertex and index arrays and of the bytes it packed
// them into, keeping what the CPU still reads: what the listeners pick
// (../listen/pick.as: the visible triangles, kept by GpuMesh.releaseCpu),
// a lightmapped item's coordinates (../render/lightmap.as builds its mesh
// from the source in the plan that uploads it, and shares it), a deforming
// mesh's (skinning on the CPU or the GPU, blend shapes: never released),
// the decals' textures, a panorama's texels (both pinned), and what is
// pinned.
//
// The objects stay: an Image keeps its width and height and is still the
// key the renderers' texture shares find its upload by; only its bytes go
// (render/image.as Image.releasePixels, texture/format.as
// CompressedImage.releaseLevels, render/mesh.as GpuMesh.releaseCpu). So
// nothing that binds, sorts or keys a resource changes, and every picture
// stays the same.
//
// When: the uploaders tell the releaser (an UploadListener) what went up
// (TextureShare.upload and uploadCompressed: render/material.as;
// GpuMeshUploader.upload: render/gpu/mesh_cache.as); it records each as
// due, and releasePendingCpuCopies, which the run time calls at the start
// of the next frame's advance (runtime_resources.as
// ResourceCacheHook.advanced), lets go of them: after the frame that
// uploaded them drew, so every buffer that frame made on first use exists.
// A buffer made on first use later (a mesh culled in that frame, drawn
// with UV set 1 later: gpu/mesh_cache.as uv1Buffer) would have nothing to
// be made from, so the releaser makes those of a mesh first (UV set 1, the
// lightmap coordinates: 8 bytes a vertex each on the device). Recording
// allocates at the load; a frame with nothing due allocates nothing.
//
// What is never released: a pinned object; an image under
// CPU_COPY_MIN_IMAGE_BYTES (the 1 x 1 fallbacks and the viewports' shared
// blank texel among them: too small to matter, and shared by every
// runtime); a mesh that deforms (GpuMesh.deforms, a skin, blend shapes,
// whose vertices are read every frame); anything under CPU_COPY_KEEP.
//
// The opt-in (Godot's PortableCompressedTexture2D.keep_compressed_buffer
// is per texture; Hedra's is the project's and the run time's):
// hedra.yaml's `memory/keep_cpu_copies: true` keeps every copy (re-upload
// after a device loss, a script reading pixels); `pinImage`, `pinForm` and
// `pinMesh` keep one (what a part of the engine reads on the CPU after the
// upload pins it before the release). The tools keep every copy
// (CPU_COPY_KEEP, the default: nothing is installed).
//
// A reader that finds a released copy it needed counts a miss
// (`noteCpuMiss`): a bug (every reader pins or works out what it needs
// first); the tests assert none. Built with `--define=HEDRA_CPU_COPY_RELEASE`
// (tools/unit-test.sh), the module starts with the policy forced on, so
// that whole suites run with every copy released as a run time releases
// them, and a miss throws (the test that made it fails, naming what
// missed) unless the test said it makes misses on purpose
// (`expectCpuMisses`): tools/test-everything.sh runs the runtime, listen,
// decal and lights suites so.

import { Image } from "../../render/image";
import { GpuMesh } from "../../render/mesh";
import { CompressedImage } from "../../texture/format";
import { UploadListener, addUploadListener, removeUploadListener } from "../../render/upload_events";
import { GpuMeshBuffers, lightmapUvBuffer, uv1Buffer } from "../../render/gpu/mesh_cache";

// The policies: keep every CPU copy (the tools, and a project that opts
// in), or release what an upload made redundant (a run time).
export const CPU_COPY_KEEP: i32 = 0;
export const CPU_COPY_RELEASE: i32 = 1;

// Images smaller than this keep their pixels (a 32 x 32 RGBA8 texture):
// releasing them saves nothing worth the bookkeeping, and the engine's
// shared constant images (a viewport's blank texel, the fallbacks) are
// among them.
export const CPU_COPY_MIN_IMAGE_BYTES: i32 = 4096;

// Whether the build forces the release on (see the header).
const FORCED: bool = isDefined(HEDRA_CPU_COPY_RELEASE);
export const CPU_COPY_FORCED: bool = FORCED;

export class CpuCopyStats {
    // Textures and meshes whose CPU side was released, and the bytes it
    // held.
    texturesReleased: i64 = 0;
    meshesReleased: i64 = 0;
    bytesReleased: i64 = 0;
    // Objects kept for a pin.
    pinned: i64 = 0;
    // A CPU reader that found a released copy (a bug: every reader pins
    // first; the tests assert 0), and what the last one was.
    misses: i64 = 0;
    lastMiss: string = "";
}

// Told of each release (the run time's cache recounts its entries' CPU
// bytes: runtime_resources.as). `img`, `form` or `mesh` is what was
// released (an image and the form it was decoded from go together), and
// `bytes` what they held.
export abstract class CpuReleaseListener {
    released(img: Image?, form: CompressedImage?, mesh: GpuMesh?, bytes: i64): void {}
}

let policy: i32 = FORCED ? CPU_COPY_RELEASE : CPU_COPY_KEEP;
let stats: CpuCopyStats? = null;
// Whether a released mesh keeps its visible triangles for the listeners'
// picking (GpuMesh.releaseCpu keepTriangles; see setPickTrianglesKept).
let pickTriangles: bool = true;
// What is due (see the header): each texture upload's image and form (one
// of them may be null), by upload, and the meshes. Null until the first
// (constant initial values, as upload_events.as's listeners).
let dueImages: Array<Image?>? = null;
let dueForms: Array<CompressedImage?>? = null;
let dueMeshes: Array<GpuMesh>? = null;
let releaseListeners: Array<CpuReleaseListener>? = null;

export function cpuCopyPolicy(): i32 {
    return policy;
}

export function cpuCopyStats(): CpuCopyStats {
    let s = stats;
    if (s == null) {
        s = new CpuCopyStats();
        stats = s;
    }
    return s;
}

// Keeps `img`'s pixels after its upload. A flag on the image: nothing is
// held, nothing allocated, and pinning again changes nothing. A pin after
// the release keeps nothing (the reader checks `img.released`).
export function pinImage(img: Image): void {
    if (img.pinned) return;
    img.pinned = true;
    cpuCopyStats().pinned++;
}

// Keeps `form`'s levels after its upload.
export function pinForm(form: CompressedImage): void {
    if (form.pinned) return;
    form.pinned = true;
    cpuCopyStats().pinned++;
}

// Keeps `mesh`'s arrays after its upload.
export function pinMesh(mesh: GpuMesh): void {
    if (mesh.cpuPinned) return;
    mesh.cpuPinned = true;
    cpuCopyStats().pinned++;
}

// Whether `mesh`'s CPU arrays were released (a reader that needs them and
// finds this true counts a miss).
export function meshCpuReleased(mesh: GpuMesh): bool {
    return mesh.cpuReleased;
}

// Whether a miss is made on purpose (expectCpuMisses), so that a build
// forcing the release on counts it rather than throwing.
let missesExpected: bool = false;

// A reader found a released copy it needed (see the header). Allocates
// nothing (but under the forced release, where an unexpected miss throws).
export function noteCpuMiss(what: string): void {
    const s = cpuCopyStats();
    s.misses++;
    s.lastMiss = what;
    if (FORCED && !missesExpected) throw new Error("a CPU copy was missed after its release (" + what + ")");
}

// The test that calls it makes misses on purpose (counted, never thrown,
// until resetCpuCopies; see the header).
export function expectCpuMisses(): void {
    missesExpected = true;
}

// Whether released meshes keep their visible triangles for the listeners'
// picking (true by default: a scene with a pointer listener, or an
// artboard texture that hears the pointer, picks every drawn mesh, a wall
// hiding a button; 16 bytes a triangle and 20 a vertex: render/mesh.as
// MeshTriangles). A run time whose scenes never pick may turn it off; a
// pick on a mesh released without them hits nothing there and counts a
// miss.
export function setPickTrianglesKept(on: bool): void {
    pickTriangles = on;
}

export function pickTrianglesKept(): bool {
    return pickTriangles;
}

export function addCpuReleaseListener(l: CpuReleaseListener): void {
    let a = releaseListeners;
    if (a == null) {
        a = new Array<CpuReleaseListener>();
        releaseListeners = a;
    }
    for (let i = 0; i < a.length; i++) if (a[i] === l) return;
    a.push(l);
}

export function removeCpuReleaseListener(l: CpuReleaseListener): void {
    const a = releaseListeners;
    if (a == null) return;
    for (let i = 0; i < a.length; i++) {
        if (a[i] === l) {
            a.splice(i, 1);
            return;
        }
    }
}

// How many uploads are due for release (tests).
export function cpuCopiesDue(): i32 {
    const im = dueImages;
    const ms = dueMeshes;
    return (im != null ? im.length : 0) + (ms != null ? ms.length : 0);
}

// The listener that records what is due.
class CpuCopyReleaser extends UploadListener {
    textureUploaded(img: Image?, form: CompressedImage?, srgb: bool, bytes: i64): void {
        if (policy != CPU_COPY_RELEASE) return;
        let im = dueImages;
        let fm = dueForms;
        if (im == null || fm == null) {
            im = new Array<Image?>();
            fm = new Array<CompressedImage?>();
            dueImages = im;
            dueForms = fm;
        }
        im.push(img);
        fm.push(form);
    }

    meshUploaded(mesh: GpuMesh, bytes: i64): void {
        if (policy != CPU_COPY_RELEASE) return;
        let ms = dueMeshes;
        if (ms == null) {
            ms = new Array<GpuMesh>();
            dueMeshes = ms;
        }
        ms.push(mesh);
    }

    // (a texture or a mesh let go of before its release needs nothing
    // here: releasing what is left of a freed object frees it sooner)
}

let releaser: CpuCopyReleaser? = null;

function releasable(img: Image): bool {
    return !img.pinned && !img.released && img.data.length >= CPU_COPY_MIN_IMAGE_BYTES;
}

// Whether `mesh` may let go of its arrays: uploaded, not pinned, and not
// one whose vertices are read again (a node's blended or skinned copy,
// GpuMesh.deforms; a skin, which the skinned pipelines' check and the
// CPU skinning read: scene/render/skinning.as; blend shapes, which
// scene/render/morph.as blends from the base every frame).
function releasableMesh(mesh: GpuMesh): bool {
    return !mesh.cpuPinned && !mesh.cpuReleased && !mesh.deforms && mesh.morphs == null && mesh.skinJoints == null
        && mesh.gpu != null;
}

// The device buffers `mesh`'s draws make on first use, made now (see the
// header): UV set 1 (every mesh: a material may draw it with the extended
// or the custom pipelines) and the lightmap coordinates (a lightmapped
// mesh; uploaded with it, made here only if they were set after). Only
// for the device's own buffers (a test's fake uploader has none to make),
// and not for buffers released already (FrameRenderer.retire empties
// them).
function makeLazyBuffers(mesh: GpuMesh): void {
    const g = mesh.gpu;
    if (g == null || !(g instanceof GpuMeshBuffers)) return;
    const b = g as GpuMeshBuffers;
    if (b.tris == null) return;
    uv1Buffer(mesh);
    if (mesh.lightmapUv != null) lightmapUvBuffer(mesh);
}

function tell(img: Image?, form: CompressedImage?, mesh: GpuMesh?, bytes: i64): void {
    const a = releaseListeners;
    if (a == null) return;
    for (let i = 0; i < a.length; i++) unchecked(a[i]).released(img, form, mesh, bytes);
}

// Lets go of the CPU copies of everything uploaded since the last call
// (see the header). Called by the run time at the start of a frame's
// advance; nothing due (every frame but those after a load) allocates
// nothing and costs two length tests. Under CPU_COPY_KEEP (a project that
// opted in after the uploads were recorded) the due list is dropped and
// everything kept.
export function releasePendingCpuCopies(): void {
    const im = dueImages;
    const fm = dueForms;
    const ms = dueMeshes;
    const nt = im != null ? im.length : 0;
    const nm = ms != null ? ms.length : 0;
    if (nt == 0 && nm == 0) return;
    if (policy == CPU_COPY_RELEASE) {
        const s = cpuCopyStats();
        if (im != null && fm != null) {
            for (let i = 0; i < nt; i++) {
                const img = unchecked(im[i]);
                const form = unchecked(fm[i]);
                let bytes: i64 = 0;
                if (img != null && releasable(img)) bytes += img.releasePixels();
                if (form != null && !form.pinned && !form.released) bytes += form.releaseLevels();
                if (bytes <= 0) continue;
                s.texturesReleased++;
                s.bytesReleased += bytes;
                tell(img, form, null, bytes);
            }
        }
        if (ms != null) {
            const keep = pickTriangles;
            for (let i = 0; i < nm; i++) {
                const mesh = unchecked(ms[i]);
                if (!releasableMesh(mesh)) continue;
                makeLazyBuffers(mesh);
                const bytes = mesh.releaseCpu(keep);
                s.meshesReleased++;
                s.bytesReleased += bytes;
                tell(null, null, mesh, bytes);
            }
        }
    }
    if (im != null) im.length = 0;
    if (fm != null) fm.length = 0;
    if (ms != null) ms.length = 0;
}

// Installs the run time's policy: CPU_COPY_RELEASE unless `keep` (the
// project's memory/keep_cpu_copies). Called by the run time's resource hook
// at each load (../runtime/runtime_resources.as); idempotent.
export function installCpuCopies(keep: bool): void {
    policy = keep && !FORCED ? CPU_COPY_KEEP : CPU_COPY_RELEASE;
    let r = releaser;
    if (r == null) {
        r = new CpuCopyReleaser();
        releaser = r;
        addUploadListener(r);
    }
}

// Back to the tools' policy (tests): CPU_COPY_KEEP, the releaser no longer
// listening, nothing due, the counts at 0, triangles kept, no release
// listener. A build that forces the release on (see the header) stays
// forced.
export function resetCpuCopies(): void {
    policy = FORCED ? CPU_COPY_RELEASE : CPU_COPY_KEEP;
    stats = new CpuCopyStats();
    missesExpected = false;
    pickTriangles = true;
    const im = dueImages;
    if (im != null) im.length = 0;
    const fm = dueForms;
    if (fm != null) fm.length = 0;
    const ms = dueMeshes;
    if (ms != null) ms.length = 0;
    const ls = releaseListeners;
    if (ls != null) ls.length = 0;
    const r = releaser;
    if (r != null && !FORCED) {
        removeUploadListener(r);
        releaser = null;
    }
}

// (forced: the releaser listens from the start)
if (FORCED) installCpuCopies(false);
