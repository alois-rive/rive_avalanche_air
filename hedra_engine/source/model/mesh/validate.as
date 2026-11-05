// Topological invariants. `validate` is cheap
// enough to run after every operator while DEBUG_ASSERTIONS is on
// (`Mesh.debugValidate`) and is what the kernel tests assert on.
//
// Two walks here iterate maps (the vert -> edges index and the per-edge face
// lists built below); both go in Map insertion order, so the first violation
// reported is deterministic.

import { Result } from "../../../base/util";
import { debugList } from "../../../base/fmt";
import { Mesh, ElemKind } from "./mod";

function u32List(xs: Array<u32>): string {
    const parts: Array<string> = [];
    for (let i = 0; i < xs.length; i++) parts.push(xs[i].toString());
    return debugList(parts);
}

function sortedU32(xs: Array<u32>): Array<u32> {
    const a = xs.slice(0);
    a.sort((x: u32, y: u32): i32 => (x < y ? -1 : (x > y ? 1 : 0)));
    return a;
}

function sameU32(a: Array<u32>, b: Array<u32>): bool {
    if (a.length != b.length) return false;
    for (let i = 0; i < a.length; i++) if (a[i] != b[i]) return false;
    return true;
}

function fail(msg: string): Result<bool> {
    return Result.fail<bool>(msg);
}

// Ok(true), or the first violation as the error.
export function validateMesh(m: Mesh): Result<bool> {
    // Edges: live distinct verts, unique, in the lookup and vert index.
    const seen = new Set<u64>();
    const eb = m.edges.idBound();
    for (let id: u32 = 0; id < eb; id++) {
        const e = m.edges.get(id);
        if (e == null) continue;
        const a = e.v[0];
        const b = e.v[1];
        if (a == b) return fail(`edge ${id} is degenerate (${a}-${a})`);
        for (let k = 0; k < 2; k++) {
            const v = k == 0 ? a : b;
            if (!m.verts.contains(v)) return fail(`edge ${id} references missing vert ${v}`);
            if (!m.vertEdges(v).includes(id)) return fail(`vert ${v} does not list edge ${id}`);
        }
        const key: u64 = a < b ? ((<u64>a << 32) | <u64>b) : ((<u64>b << 32) | <u64>a);
        if (seen.has(key)) return fail(`duplicate edge ${id} between ${a} and ${b}`);
        seen.add(key);
        if (m.findEdge(a, b) != id) return fail(`edge lookup does not resolve ${a}-${b} to ${id}`);
    }
    const vkeys = m.vertEdgesMap.keys();
    for (let i = 0; i < vkeys.length; i++) {
        const v = vkeys[i];
        if (!m.verts.contains(v)) return fail(`vert index lists missing vert ${v}`);
        const list = m.vertEdgesMap.get(v);
        for (let j = 0; j < list.length; j++) {
            const e = list[j];
            const edge = m.edges.get(e);
            if (!(edge != null && edge.hasVert(v))) return fail(`vert ${v} lists edge ${e} that does not use it`);
        }
    }
    // Faces and loops.
    const loopsSeen = new Set<u32>();
    const edgeFaceCount = new Map<u32, Array<u32>>();
    const fb = m.faces.idBound();
    for (let fid: u32 = 0; fid < fb; fid++) {
        const f = m.faces.get(fid);
        if (f == null) continue;
        if (f.loopLen < 3) return fail(`face ${fid} has ${f.loopLen} loops`);
        const ring = f.loops();
        const verts: Array<u32> = [];
        for (let i = 0; i < ring.length; i++) {
            const l = ring[i];
            const lp = m.loops.get(l);
            if (lp == null) return fail(`face ${fid} references missing loop ${l}`);
            if (loopsSeen.has(l)) return fail(`loop ${l} is used by two faces`);
            loopsSeen.add(l);
            if (lp.face != fid) return fail(`loop ${l} belongs to face ${lp.face} not ${fid}`);
            if (!m.verts.contains(lp.vert)) return fail(`loop ${l} references missing vert ${lp.vert}`);
            // `at` panics on a hole: a dangling next loop is a kernel bug.

            const next = m.loops.at(ring[(i + 1) % ring.length]).vert;
            const edge = m.edges.get(lp.edge);
            if (edge == null) return fail(`loop ${l} references missing edge ${lp.edge}`);
            if (!(edge.hasVert(lp.vert) && edge.hasVert(next))) {
                return fail(`loop ${l} edge ${lp.edge} does not join ${lp.vert} and ${next}`);
            }
            if (lp.uv.length != m.uvLayers.length) {
                return fail(`loop ${l} has ${lp.uv.length} uvs for ${m.uvLayers.length} layers`);
            }
            if (edgeFaceCount.has(lp.edge)) edgeFaceCount.get(lp.edge).push(fid);
            else edgeFaceCount.set(lp.edge, [fid]);
            verts.push(lp.vert);
        }
        const distinct = sortedU32(verts);
        let w = distinct.length > 0 ? 1 : 0;
        for (let i = 1; i < distinct.length; i++) {
            if (distinct[i] != distinct[w - 1]) {
                distinct[w] = distinct[i];
                w++;
            }
        }
        if (w != verts.length) return fail(`face ${fid} repeats a vertex: ${u32List(verts)}`);
        if (f.select && f.hide) return fail(`face ${fid} is both selected and hidden`);
    }
    if (loopsSeen.size != m.loops.len()) {
        return fail(`${m.loops.len() - loopsSeen.size} loops are not owned by any face`);
    }
    // Edge -> face index matches the loops.
    const ekeys = edgeFaceCount.keys();
    for (let i = 0; i < ekeys.length; i++) {
        const e = ekeys[i];
        const a = sortedU32(edgeFaceCount.get(e));
        const b = sortedU32(m.edgeFaces(e));
        if (!sameU32(a, b)) return fail(`edge ${e} face index ${u32List(b)} does not match loops ${u32List(a)}`);
    }
    const fkeys = m.edgeFacesMap.keys();
    for (let i = 0; i < fkeys.length; i++) {
        const e = fkeys[i];
        const faces = m.edgeFacesMap.get(e);
        if (faces.length > 0 && !edgeFaceCount.has(e)) {
            return fail(`edge ${e} lists faces ${u32List(faces)} but no loop uses it`);
        }
    }
    const vb = m.verts.idBound();
    for (let id: u32 = 0; id < vb; id++) {
        const v = m.verts.get(id);
        if (v == null) continue;
        if (v.select && v.hide) return fail(`vert ${id} is both selected and hidden`);
        if (!v.co.isFinite()) return fail(`vert ${id} has a non-finite position`);
    }
    for (let id: u32 = 0; id < eb; id++) {
        const e = m.edges.get(id);
        if (e == null) continue;
        if (e.select && e.hide) return fail(`edge ${id} is both selected and hidden`);
    }
    for (let i = 0; i < m.selectionHistory.length; i++) {
        const r = m.selectionHistory[i];
        if (!m.contains(r.kind, r.id)) {
            return fail(`selection history references missing ${ElemKind.name(r.kind)} ${r.id}`);
        }
    }
    return Result.okv<bool>(true);
}
