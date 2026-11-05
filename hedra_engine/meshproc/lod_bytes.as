// Milestone 26, package WP2: levels of detail as bytes, and the checks a
// reader makes of them, without the simplifier (meshproc/lods.as makes
// the levels): what the import cache (import/lods_file.as), a bundle's
// Mesh entries and its Lods entries (engine/src/scene/bundle) hold, so that the
// run time reads levels without carrying the code that makes
// them.
//
// encodeLods / decodeLods are the levels' bytes, little endian:
//   u32 levels, then per level: f32 error, u32 ranges, per range
//   (u32 slot, u32 first, u32 count), u32 index count, the u32 indices.

import { Result, fnv1a64Bytes } from "../base/util";
import { hexU64 } from "../base/fmt";
import { GpuMesh, MaterialRange, MeshLod } from "../render/mesh";

// The key of a mesh's levels in a bundle's Lods entries (a primitive
// mesh's, which the run time builds from the scene and finds its levels
// by): the FNV-1a 64 of its vertex count, its ranges, its indices and its
// positions' bits, 16 lower-case hex digits. The tools and the run time
// build a primitive's GpuMesh with the same code, so they agree.
export function meshLodKey(g: GpuMesh): string {
    const nv = g.verts.length;
    const ni = g.indices.length;
    const nr = g.ranges.length;
    const b = new Uint8Array(8 + nr * 12 + ni * 4 + nv * 12);
    const dv = new DataView(b.buffer, 0, b.byteLength);
    let o = 0;
    dv.setUint32(o, <u32>nv, true);
    dv.setUint32(o + 4, <u32>nr, true);
    o += 8;
    for (let k = 0; k < nr; k++) {
        const r = g.ranges[k];
        dv.setUint32(o, <u32>r.slot, true);
        dv.setUint32(o + 4, r.first, true);
        dv.setUint32(o + 8, r.count, true);
        o += 12;
    }
    for (let k = 0; k < ni; k++) {
        dv.setUint32(o, g.indices[k], true);
        o += 4;
    }
    for (let k = 0; k < nv; k++) {
        const p = g.verts[k].pos;
        dv.setFloat32(o, p.x, true);
        dv.setFloat32(o + 4, p.y, true);
        dv.setFloat32(o + 8, p.z, true);
        o += 12;
    }
    return hexU64(fnv1a64Bytes(b), 16);
}

// Whether `lods` (an import's cached levels) fit `g`: the ranges of each
// level as many as the mesh's, each within the level, whole triangles,
// every index one of its vertices. The tools' level source and the
// asset container's writer both ask it before using a cache made from what
// may be another mesh.
export function lodsFit(lods: Array<MeshLod>, g: GpuMesh): bool {
    const n = <u32>g.verts.length;
    for (let i = 0; i < lods.length; i++) {
        const l = lods[i];
        if (l.ranges.length != g.ranges.length || l.indices.length % 3 != 0) return false;
        for (let k = 0; k < l.ranges.length; k++) {
            const r = l.ranges[k];
            if (<u64>r.first + <u64>r.count > <u64>l.indices.length) return false;
        }
        for (let k = 0; k < l.indices.length; k++) if (l.indices[k] >= n) return false;
    }
    return true;
}

// The levels back from encodeLods' bytes. `vertexCount` checks every
// index; `what` names the bytes in a failure. Fails, never traps, on bytes
// it did not write: a short read, a count past the bytes, an index count
// that is not whole triangles, a range past its level's indices, a slot
// past 65535, an index past the vertices, or bytes left over.
export function decodeLods(bytes: Uint8Array, vertexCount: i32, what: string): Result<Array<MeshLod>> {
    const n = bytes.length;
    const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    if (n < 4) return Result.fail<Array<MeshLod>>(what + ": levels of detail: " + n.toString() + " bytes, too short for the level count");
    const levels = dv.getUint32(0, true);
    // Each level takes 12 bytes at least.
    if (<u64>levels * 12 > <u64>(n - 4)) {
        return Result.fail<Array<MeshLod>>(what + ": levels of detail: " + levels.toString() + " levels do not fit in " + n.toString() + " bytes");
    }
    const out = new Array<MeshLod>();
    let o = 4;
    for (let i: u32 = 0; i < levels; i++) {
        const name = what + ": level " + (i + 1).toString();
        if (o + 8 > n) return Result.fail<Array<MeshLod>>(name + ": the bytes end in its header");
        const lod = new MeshLod();
        lod.error = dv.getFloat32(o, true);
        if (!(lod.error >= 0) || !isFinite(lod.error)) return Result.fail<Array<MeshLod>>(name + ": error " + lod.error.toString() + " is not a finite number of 0 or more");
        const rc = dv.getUint32(o + 4, true);
        o += 8;
        if (<u64>rc * 12 + 4 > <u64>(n - o)) return Result.fail<Array<MeshLod>>(name + ": " + rc.toString() + " ranges run past the bytes");
        for (let k: u32 = 0; k < rc; k++) {
            const slot = dv.getUint32(o, true);
            const first = dv.getUint32(o + 4, true);
            const count = dv.getUint32(o + 8, true);
            o += 12;
            if (slot > 0xFFFF) return Result.fail<Array<MeshLod>>(name + ": range " + k.toString() + " names slot " + slot.toString() + " (at most 65535)");
            lod.ranges.push(MaterialRange(<u16>slot, first, count));
        }
        const ic = dv.getUint32(o, true);
        o += 4;
        if (<u64>ic * 4 > <u64>(n - o)) return Result.fail<Array<MeshLod>>(name + ": " + ic.toString() + " indices run past the bytes");
        if (ic % 3 != 0) return Result.fail<Array<MeshLod>>(name + ": " + ic.toString() + " indices are not whole triangles");
        for (let k = 0; k < lod.ranges.length; k++) {
            const r = lod.ranges[k];
            if (<u64>r.first + <u64>r.count > <u64>ic || r.first % 3 != 0 || r.count % 3 != 0) {
                return Result.fail<Array<MeshLod>>(name + ": range " + k.toString() + " (" + r.first.toString() + ", " + r.count.toString()
                    + ") is not whole triangles within its " + ic.toString() + " indices");
            }
        }
        for (let k: u32 = 0; k < ic; k++) {
            const v = dv.getUint32(o, true);
            o += 4;
            if (<u64>v >= <u64>vertexCount) {
                return Result.fail<Array<MeshLod>>(name + ": index " + v.toString() + " is past the mesh's " + vertexCount.toString() + " vertices");
            }
            lod.indices.push(v);
        }
        out.push(lod);
    }
    if (o != n) return Result.fail<Array<MeshLod>>(what + ": levels of detail: " + (n - o).toString() + " bytes left over");
    return Result.okv<Array<MeshLod>>(out);
}
