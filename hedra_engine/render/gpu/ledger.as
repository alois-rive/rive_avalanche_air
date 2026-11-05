// What the GPU holds for the program's resources (milestone 67b,
// docs/engine/RESOURCES.md): the bytes and objects every texture and mesh
// buffer upload charged, refunded when they are released, and the queue of
// GPU objects let go of and released one frame later.
//
// The host's API reports no GPU memory, so the ledger is Hedra's own
// account: each upload charges the bytes it handed the device (a texture's
// whole mip chain in the format it was made in, a mesh's buffers), and each
// release refunds the same number. A test reads `textureBytes`,
// `bufferBytes`, `textures` and `buffers` before a load and after the last
// instance is freed: they must be back where they were (the leak check of
// docs/engine/RESOURCES.md, "Lifetimes"). `hedra inspect --resources`, the
// run time's status (`"resources"`) and the editor's Monitors read the
// same figures.
//
// Releasing waits a frame: a GPU object a view recorded earlier in the
// frame may still be read by the GPU, so what the resource cache frees goes
// to `retire` and is released by `flushRetired`, which the run time calls
// at the start of each instance's advance (the renderer releases its own
// per-frame objects the same way, at its next beginFrame).
//
// Imports nothing of rive/gpu: what releases an object is the GpuRelease
// its uploader made, so the ledger and its tests run without a device.
//
// What it counts: one texture per uploaded image or form, one buffer per
// mesh's set of buffers (its vertices, indices, wire edges and points, and
// what goes up with them: GpuMeshBuffers), each with the bytes the
// uploader handed the device. The resource cache's hook
// (../../scene/runtime/runtime_resources.as) charges an upload to the
// resource that owns it (and the release with it); an upload no resource
// owns (a live artboard's canvas, a node's blended or skinned copy of a
// mesh, a lightmapped item's mesh, a texture uploaded by a binder outside
// the run time's share) goes to the "(engine)" figures instead, which count
// what was uploaded and are never refunded (the renderer releases those
// objects itself, through its own retire), so that the resources' figures
// above return to their baseline exactly when the last instance goes.

// One GPU object (or a group of them, a mesh's buffers) that can be let go
// of: what freeing a resource releases.
export abstract class GpuRelease {
    // Releases the object(s) now (GPUTexture.release, GPUBuffer.release).
    abstract release(): void;
    // The bytes the object(s) hold on the device (what was charged).
    abstract bytes(): i64;
    // LEDGER_TEXTURE or LEDGER_BUFFER.
    abstract kind(): i32;
}

export const LEDGER_TEXTURE: i32 = 0;
export const LEDGER_BUFFER: i32 = 1;

export class GpuLedger {
    // Live textures (each an uploaded image or form) and their bytes.
    textures: i64 = 0;
    textureBytes: i64 = 0;
    // Live buffer sets (each a mesh's vertex, index, edge and point buffers
    // and those uploaded with them) and their bytes.
    buffers: i64 = 0;
    bufferBytes: i64 = 0;
    // The most bytes ever held at once (textures and buffers).
    peakBytes: i64 = 0;
    // What was let go of this frame, released at the next flushRetired.
    private retired: Array<GpuRelease> = [];
    // How many objects flushRetired released in all (tests).
    released: i64 = 0;
    // The "(engine)" uploads (see the header): how many, and their bytes.
    engineTextures: i64 = 0;
    engineTextureBytes: i64 = 0;
    engineBuffers: i64 = 0;
    engineBufferBytes: i64 = 0;

    // An upload no resource owns (see the header).
    chargeEngine(kind: i32, bytes: i64): void {
        if (kind == LEDGER_TEXTURE) {
            this.engineTextures++;
            this.engineTextureBytes += bytes;
        } else {
            this.engineBuffers++;
            this.engineBufferBytes += bytes;
        }
    }

    // A resource's object uploaded again in place of its first upload (a
    // mesh given its levels of detail after its first draw: the old
    // buffers are the renderer's to release): the charge moves from
    // `before` to `after` bytes, the count unchanged.
    recharge(kind: i32, before: i64, after: i64): void {
        if (kind == LEDGER_TEXTURE) this.textureBytes += after - before;
        else this.bufferBytes += after - before;
        const now = this.textureBytes + this.bufferBytes;
        if (now > this.peakBytes) this.peakBytes = now;
    }

    // An upload of `bytes` of `kind` (LEDGER_TEXTURE, LEDGER_BUFFER).
    charge(kind: i32, bytes: i64): void {
        if (kind == LEDGER_TEXTURE) {
            this.textures++;
            this.textureBytes += bytes;
        } else {
            this.buffers++;
            this.bufferBytes += bytes;
        }
        const now = this.textureBytes + this.bufferBytes;
        if (now > this.peakBytes) this.peakBytes = now;
    }

    // The release of what `charge(kind, bytes)` charged.
    refund(kind: i32, bytes: i64): void {
        if (kind == LEDGER_TEXTURE) {
            this.textures--;
            this.textureBytes -= bytes;
        } else {
            this.buffers--;
            this.bufferBytes -= bytes;
        }
    }

    // Lets go of `r`: refunded now, released at the next flushRetired.
    retire(r: GpuRelease): void {
        this.refund(r.kind(), r.bytes());
        this.retired.push(r);
    }

    // How many objects wait for flushRetired.
    get pending(): i32 {
        return this.retired.length;
    }

    // Releases what was retired before this call (the list keeps its
    // storage: a frame with nothing retired allocates nothing).
    flushRetired(): void {
        const n = this.retired.length;
        if (n == 0) return;
        for (let i = 0; i < n; i++) unchecked(this.retired[i]).release();
        this.released += n;
        this.retired.length = 0;
    }

    // Every GPU byte the ledger holds.
    totalBytes(): i64 {
        return this.textureBytes + this.bufferBytes;
    }
}

// The module's one ledger (every runtime of a Rive file draws on one
// device).
let theLedger: GpuLedger? = null;

export function gpuLedger(): GpuLedger {
    let l = theLedger;
    if (l == null) {
        l = new GpuLedger();
        theLedger = l;
    }
    return l;
}

// A fresh ledger (tests: each starts from 0).
export function resetGpuLedger(): GpuLedger {
    const l = new GpuLedger();
    theLedger = l;
    return l;
}

// The bytes an uncompressed upload of a `w` x `h` image takes with its
// whole mip chain (render/gpu/materials.as uploadTexture: rgba16float, 8
// bytes a texel, for a colour slot sampled as sRGB; rgba8unorm, 4, else).
export function imageUploadBytes(w: u32, h: u32, srgb: bool): i64 {
    const bpp: i64 = srgb ? 8 : 4;
    let total: i64 = 0;
    let lw = w > 0 ? w : 1;
    let lh = h > 0 ? h : 1;
    while (true) {
        total += <i64>lw * <i64>lh * bpp;
        if (lw == 1 && lh == 1) break;
        lw = lw > 1 ? lw >> 1 : 1;
        lh = lh > 1 ? lh >> 1 : 1;
    }
    return total;
}

// The bytes of `levels` (a compressed form's level sizes, as uploaded).
export function levelsBytes(sizes: Array<i32>): i64 {
    let total: i64 = 0;
    for (let i = 0; i < sizes.length; i++) total += <i64>sizes[i];
    return total;
}
