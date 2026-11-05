// Scratch buffers for decoding (milestone 67b, docs/engine/RESOURCES.md,
// "Loading"): a pool of byte buffers that a decoder takes for the bytes it
// throws away when it is done (a PNG's inflated rows before they are
// unfiltered, a KTX2 level inflated for its upload, a mesh's vertex stream
// before it is laid out, a mip chain converted for the GPU), instead of
// allocating them for every texture and mesh a load reads.
//
//   const tmp = scratch().take(rowBytes * height);   // length exactly that
//   ... inflate into tmp, unfilter out of it ...
//   scratch().give(tmp);                              // back to the pool
//
// Buffers are kept by size class (powers of two from 4 KiB), so a buffer
// given back serves any later request of its class or below; `take` hands
// out a view of exactly the length asked for, over the class's buffer. A
// buffer's bytes are whatever its last user left: a decoder writes every
// byte it reads back. `trim` lets go of everything (the run time trims when
// a load is done, so that what a load needed is not held while the scene
// plays); past `maxHeldBytes`, a given buffer is dropped rather than kept.
//
// One pool per thread of the program: the module's (`scratch()`), and on
// Rive's script threads each lane's own module has its own (milestone 64's
// background loading decodes on lanes with their pools). Deterministic: the
// bytes a decoder produces never depend on which buffer it was given.
//
// Who takes from it (milestone 67b): the PNG decoder's unfiltering
// window and its inflater (render/png.as, one Inflate kept free between
// streams), the pixels of a PNG that is not RGBA before they are widened
// (decodePngPooled), the KTX2 reader's inflater (texture/ktx2.as: a
// level is inflated straight into its own buffer, and an uncompressed
// level is a view of the file's bytes, so neither needs scratch), the
// meshoptimizer vertex and index decoders' block buffers and outputs
// (io/compress/meshopt: decodeViewPooled) and the prebuilt meshes' vertex
// codec (meshproc/vertex_codec.as), whose quantised vertices and indices
// are read out of pooled bytes into the mesh's arrays. The mip chains and
// mesh packing of the uploads take from it too (render/gpu/materials.as,
// render/gpu/mesh_cache.as).
//
// Giving a buffer back twice would hand it to two users at once: `give`
// keeps a buffer once whatever it is given. A view the pool did not make
// (its buffer not a class's size) is let go.

// The smallest class (4 KiB) and the largest (1 GiB).
export const SCRATCH_MIN_SHIFT: i32 = 12;
export const SCRATCH_MAX_SHIFT: i32 = 30;

// The bytes the pool keeps at most (64 MiB) before it drops a buffer
// given back.
export const SCRATCH_DEFAULT_HELD: i64 = 64 << 20;

export class ScratchPool {
    // Free buffers by class (index: shift - SCRATCH_MIN_SHIFT).
    private free: Array<Array<ArrayBuffer>> = [];
    // The bytes the free buffers hold.
    heldBytes: i64 = 0;
    maxHeldBytes: i64 = SCRATCH_DEFAULT_HELD;
    // Buffers allocated, and requests served by a free one (tests,
    // `--stats`).
    made: i64 = 0;
    reused: i64 = 0;
    // The largest request so far.
    largest: i32 = 0;
    // The bytes allocated for requests (the classes' sizes), and the bytes
    // of the requests a free buffer served (what the pool spared the heap:
    // the load_cost bench and `--stats` report them).
    madeBytes: i64 = 0;
    reusedBytes: i64 = 0;
    // Buffers given back and kept, and given back but let go (past
    // maxHeldBytes, or not the pool's).
    given: i64 = 0;
    dropped: i64 = 0;

    constructor() {
        for (let s = SCRATCH_MIN_SHIFT; s <= SCRATCH_MAX_SHIFT; s++) this.free.push(new Array<ArrayBuffer>());
    }

    // A view of exactly `bytes` bytes over a pooled buffer (its bytes are
    // whatever its last user left). 0 bytes: one shared empty view, which
    // `give` lets go.
    take(bytes: i32): Uint8Array {
        if (bytes <= 0) return EMPTY;
        if (bytes > this.largest) this.largest = bytes;
        const k = classOf(bytes);
        if (k < 0) {
            // (beyond the largest class: made for this request alone)
            this.made++;
            this.madeBytes += <i64>bytes;
            return new Uint8Array(bytes);
        }
        const list = unchecked(this.free[k]);
        let buf: ArrayBuffer;
        if (list.length > 0) {
            buf = list.pop();
            this.heldBytes -= <i64>buf.byteLength;
            this.reused++;
            this.reusedBytes += <i64>bytes;
        } else {
            buf = new ArrayBuffer(1 << (k + SCRATCH_MIN_SHIFT));
            this.made++;
            this.madeBytes += <i64>buf.byteLength;
        }
        return Uint8Array.wrap(buf, 0, bytes);
    }

    // Gives back the buffer under `view` (one `take` made).
    give(view: Uint8Array): void {
        this.giveBuffer(view.buffer);
    }

    // A view of `count` 32-bit words over a pooled buffer, and its return
    // (decoders that write u32: the meshopt index decoders).
    takeU32(count: i32): Uint32Array {
        if (count <= 0) return EMPTY_U32;
        const b = this.take(count * 4);
        return Uint32Array.wrap(b.buffer, 0, count);
    }

    giveU32(view: Uint32Array): void {
        this.giveBuffer(view.buffer);
    }

    // Gives back `buf` (the buffer under a view `take` made).
    giveBuffer(buf: ArrayBuffer): void {
        const size = buf.byteLength;
        if (size == 0) return;
        const k = exactClassOf(size);
        if (k < 0 || this.heldBytes + <i64>size > this.maxHeldBytes) {
            this.dropped++;
            return;
        }
        const list = unchecked(this.free[k]);
        // (given twice: kept once; the lists hold a few buffers each)
        for (let i = 0; i < list.length; i++) if (unchecked(list[i]) === buf) return;
        list.push(buf);
        this.heldBytes += <i64>size;
        this.given++;
    }

    // Lets go of every free buffer.
    trim(): void {
        for (let k = 0; k < this.free.length; k++) unchecked(this.free[k]).length = 0;
        this.heldBytes = 0;
    }

    // The free buffers of the class serving `bytes` (tests).
    freeOf(bytes: i32): i32 {
        const k = classOf(bytes);
        return k < 0 ? 0 : unchecked(this.free[k]).length;
    }

    // The counts back to 0 (tests and benches that measure a stretch).
    resetCounts(): void {
        this.made = 0;
        this.reused = 0;
        this.largest = 0;
        this.madeBytes = 0;
        this.reusedBytes = 0;
        this.given = 0;
        this.dropped = 0;
    }
}

// What `take(0)` hands out (never kept: its buffer is no class's).
const EMPTY: Uint8Array = new Uint8Array(0);
const EMPTY_U32: Uint32Array = new Uint32Array(0);

// The class of a request of `bytes` (-1 past the largest).
function classOf(bytes: i32): i32 {
    let s = SCRATCH_MIN_SHIFT;
    while (s <= SCRATCH_MAX_SHIFT && (1 << s) < bytes) s++;
    return s > SCRATCH_MAX_SHIFT ? -1 : s - SCRATCH_MIN_SHIFT;
}

// The class of a buffer of exactly `size` bytes (-1 for none: a buffer the
// pool did not make).
function exactClassOf(size: i32): i32 {
    for (let s = SCRATCH_MIN_SHIFT; s <= SCRATCH_MAX_SHIFT; s++) if ((1 << s) == size) return s - SCRATCH_MIN_SHIFT;
    return -1;
}

let thePool: ScratchPool? = null;

// The module's pool.
export function scratch(): ScratchPool {
    let p = thePool;
    if (p == null) {
        p = new ScratchPool();
        thePool = p;
    }
    return p;
}

// The module's pool emptied, its counts and cap back to their defaults
// (tests that measure it leave it as they found it).
export function resetScratch(): void {
    const p = scratch();
    p.trim();
    p.resetCounts();
    p.maxHeldBytes = SCRATCH_DEFAULT_HELD;
}
