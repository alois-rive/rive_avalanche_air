// Selection flags with Blender's flush
// rules, select-mode conversion, selection history (the active element),
// hiding, and saved selections.
//
// Flags on all three element types are kept consistent so operators can read
// whichever level they need: after any change, call `flushSelection` with the
// kind that was edited.
//
// Free functions `fn(m: Mesh, ...)`; `Mesh` (engine/src/source/model/mesh/mod.as) has
// one-line delegating methods for each.

import { Vec3 } from "../../../base/vecmath";
import { ElementCounts } from "../../../base/report";
import { Mesh, ElemKind, ElemRef, SelectionSet, NO_ID, VertId, EdgeId, FaceId } from "./mod";
import { SelectMode } from "./select_mode";

// What activePosition returns (null when there is no active element).
export class ActivePosition {
    co: Vec3 = Vec3(0, 0, 0);

    static new(co: Vec3): ActivePosition {
        const p = new ActivePosition();
        p.co = co;
        return p;
    }
}

// Propagate selection from the elements of `kind` to the other kinds, the way
// Blender flushes after a selection change in that select mode: faces/edges
// select their verts; edges are selected iff both verts are (vert mode) or by
// their own flag; faces iff all their edges (edge mode) / verts (vert mode)
// are selected.
export function flushSelection(m: Mesh, kind: ElemKind): void {
    const vb = m.verts.idBound();
    const eb = m.edges.idBound();
    const fb = m.faces.idBound();
    switch (kind) {
        case ElemKind.Face: {
            for (let id: u32 = 0; id < vb; id++) {
                const v = m.verts.get(id);
                if (v != null) v.select = false;
            }
            for (let id: u32 = 0; id < eb; id++) {
                const e = m.edges.get(id);
                if (e != null) e.select = false;
            }
            for (let id: u32 = 0; id < fb; id++) {
                const f = m.faces.get(id);
                if (f == null || !f.select) continue;
                for (let l = f.loopStart; l < f.loopStart + f.loopLen; l++) {
                    const lp = m.loops.at(l);
                    m.verts.at(lp.vert).select = true;
                    m.edges.at(lp.edge).select = true;
                }
            }
            break;
        }
        case ElemKind.Edge: {
            for (let id: u32 = 0; id < vb; id++) {
                const v = m.verts.get(id);
                if (v != null) v.select = false;
            }
            for (let id: u32 = 0; id < eb; id++) {
                const e = m.edges.get(id);
                if (e == null || !e.select) continue;
                m.verts.at(e.v[0]).select = true;
                m.verts.at(e.v[1]).select = true;
            }
            for (let id: u32 = 0; id < fb; id++) {
                const f = m.faces.get(id);
                if (f == null) continue;
                let all = !f.hide;
                if (all) {
                    for (let l = f.loopStart; l < f.loopStart + f.loopLen; l++) {
                        if (!m.edges.at(m.loops.at(l).edge).select) {
                            all = false;
                            break;
                        }
                    }
                }
                f.select = all;
            }
            break;
        }
        default: {
            for (let id: u32 = 0; id < eb; id++) {
                const e = m.edges.get(id);
                if (e == null) continue;
                e.select = !e.hide && m.verts.at(e.v[0]).select && m.verts.at(e.v[1]).select;
            }
            for (let id: u32 = 0; id < fb; id++) {
                const f = m.faces.get(id);
                if (f == null) continue;
                let all = !f.hide;
                if (all) {
                    for (let l = f.loopStart; l < f.loopStart + f.loopLen; l++) {
                        if (!m.verts.at(m.loops.at(l).vert).select) {
                            all = false;
                            break;
                        }
                    }
                }
                f.select = all;
            }
            break;
        }
    }
    const h = m.selectionHistory;
    const kept: Array<ElemRef> = [];
    for (let i = 0; i < h.length; i++) {
        if (m.isSelected(h[i].kind, h[i].id)) kept.push(h[i]);
    }
    m.selectionHistory = kept;
    m.touch();
}

// The element kind an operator should read for the given select mode (face
// wins over edge over vert when several are enabled).
export function primaryKind(mode: SelectMode): ElemKind {
    if (mode.face) return ElemKind.Face;
    if (mode.edge) return ElemKind.Edge;
    return ElemKind.Vert;
}

// Blender's select-mode conversion (`EDBM_selectmode_convert`): going up
// keeps only elements whose parts are all selected, going down selects the
// parts of what is selected.
export function convertSelectMode(m: Mesh, from: SelectMode, to: SelectMode): void {
    const fromKind = primaryKind(from);
    const toKind = primaryKind(to);
    if (fromKind == toKind) return;
    // Flushing from the source kind derives every other level exactly.
    flushSelection(m, fromKind);
    flushSelection(m, toKind);
}

// Select or deselect a set of ids of one kind and flush.
export function selectIds(m: Mesh, kind: ElemKind, ids: Array<u32>, select: bool): void {
    for (let i = 0; i < ids.length; i++) {
        const id = ids[i];
        if (!m.isHidden(kind, id)) m.setSelect(kind, id, select);
        if (select && m.contains(kind, id) && !m.isHidden(kind, id)) pushHistory(m, kind, id);
    }
    flushSelection(m, kind);
}

// Record an element as the most recently selected one.
export function pushHistory(m: Mesh, kind: ElemKind, id: u32): void {
    const h = m.selectionHistory;
    let w = 0;
    for (let i = 0; i < h.length; i++) {
        const r = h[i];
        if (!(r.kind == kind && r.id == id)) {
            h[w] = r;
            w++;
        }
    }
    h.length = w;
    h.push(ElemRef.new(kind, id));
    if (h.length > 256) h.shift();
}

// The active element: the last selected one still selected (a copy), or null.
export function activeElement(m: Mesh): ElemRef? {
    const h = m.selectionHistory;
    for (let i = h.length - 1; i >= 0; i--) {
        if (m.isSelected(h[i].kind, h[i].id)) return h[i].clone();
    }
    return null;
}

// Active element of a given kind, derived from the history where the kinds
// differ (the active face's last vert, the active edge, ...). NO_ID for none.
export function activeOfKind(m: Mesh, kind: ElemKind): u32 {
    const a = activeElement(m);
    if (a == null) return NO_ID;
    const k = a.kind;
    const id = a.id;
    if (k == kind) return id;
    if (k == ElemKind.Face && kind == ElemKind.Vert) {
        const vs = m.faceVerts(id);
        return vs.length > 0 ? vs[vs.length - 1] : NO_ID;
    }
    if (k == ElemKind.Face && kind == ElemKind.Edge) {
        const es = m.faceEdges(id);
        return es.length > 0 ? es[es.length - 1] : NO_ID;
    }
    if (k == ElemKind.Edge && kind == ElemKind.Vert) {
        const e = m.edges.at(id);
        return e.v[1];
    }
    if (k == ElemKind.Edge && kind == ElemKind.Face) {
        const fs = m.edgeFaces(id);
        return fs.length > 0 ? fs[0] : NO_ID;
    }
    if (k == ElemKind.Vert && kind == ElemKind.Edge) {
        const es = m.vertEdges(id);
        for (let i = 0; i < es.length; i++) {
            if (m.edges.at(es[i]).select) return es[i];
        }
        return NO_ID;
    }
    if (k == ElemKind.Vert && kind == ElemKind.Face) {
        const fs = m.vertFaces(id);
        for (let i = 0; i < fs.length; i++) {
            if (m.faces.at(fs[i]).select) return fs[i];
        }
        return NO_ID;
    }
    return NO_ID;
}

// Position of the active element (vert, edge midpoint or face center), or
// null when there is none.
export function activePosition(m: Mesh): ActivePosition? {
    const a = activeElement(m);
    if (a == null) return null;
    switch (a.kind) {
        case ElemKind.Vert: return ActivePosition.new(m.verts.at(a.id).co);
        case ElemKind.Edge: return ActivePosition.new(m.edgeCenter(a.id));
        default: return ActivePosition.new(m.faceCenter(a.id));
    }
}

// Hide the selected elements (or the unselected ones), deselecting them.
// Returns how many verts, edges and faces were hidden.

export function hideSelected(m: Mesh, unselected: bool): ElementCounts {
    const vs: Array<VertId> = [];
    const vb = m.verts.idBound();
    for (let id: u32 = 0; id < vb; id++) {
        const v = m.verts.get(id);
        if (v != null && !v.hide && v.select != unselected) vs.push(id);
    }
    // Blender hides an edge/face when any of its verts is hidden.
    const hidden = new Set<VertId>();
    for (let i = 0; i < vs.length; i++) hidden.add(vs[i]);
    const es: Array<EdgeId> = [];
    const eb = m.edges.idBound();
    for (let id: u32 = 0; id < eb; id++) {
        const e = m.edges.get(id);
        if (e != null && !e.hide && (hidden.has(e.v[0]) || hidden.has(e.v[1]))) es.push(id);
    }
    const fs: Array<FaceId> = [];
    const fb = m.faces.idBound();
    for (let id: u32 = 0; id < fb; id++) {
        const f = m.faces.get(id);
        if (f == null || f.hide) continue;
        const fv = m.faceVerts(id);
        for (let i = 0; i < fv.length; i++) {
            if (hidden.has(fv[i])) {
                fs.push(id);
                break;
            }
        }
    }
    for (let i = 0; i < vs.length; i++) {
        const vert = m.verts.at(vs[i]);
        vert.hide = true;
        vert.select = false;
    }
    for (let i = 0; i < es.length; i++) {
        const edge = m.edges.at(es[i]);
        edge.hide = true;
        edge.select = false;
    }
    for (let i = 0; i < fs.length; i++) {
        const face = m.faces.at(fs[i]);
        face.hide = true;
        face.select = false;
    }
    flushSelection(m, ElemKind.Vert);
    return ElementCounts.of(vs.length, es.length, fs.length);
}

// Reveal hidden elements; with `select` they become the selection. Returns
// how many verts, edges and faces were revealed.
export function reveal(m: Mesh, select: bool): ElementCounts {
    let nv = 0;
    let ne = 0;
    let nf = 0;
    const vb = m.verts.idBound();
    for (let id: u32 = 0; id < vb; id++) {
        const v = m.verts.get(id);
        if (v != null && v.hide) {
            v.hide = false;
            v.select = select;
            nv++;
        }
    }
    const eb = m.edges.idBound();
    for (let id: u32 = 0; id < eb; id++) {
        const e = m.edges.get(id);
        if (e != null && e.hide) {
            e.hide = false;
            e.select = select;
            ne++;
        }
    }
    const fb = m.faces.idBound();
    for (let id: u32 = 0; id < fb; id++) {
        const f = m.faces.get(id);
        if (f != null && f.hide) {
            f.hide = false;
            f.select = select;
            nf++;
        }
    }
    if (select) {
        flushSelection(m, ElemKind.Face);
        flushSelection(m, ElemKind.Vert);
    } else {
        m.touch();
    }
    return ElementCounts.of(nv, ne, nf);
}

export function selectionSet(m: Mesh): SelectionSet {
    const s = new SelectionSet();
    s.verts = m.selectedVerts();
    s.edges = m.selectedEdges();
    s.faces = m.selectedFaces();
    return s;
}

// Replace the selection with a saved set (ids that no longer exist are
// skipped; returns how many were skipped).
export function applySelectionSet(m: Mesh, set: SelectionSet): i32 {
    m.selectAll(false);
    let missing = 0;
    for (let i = 0; i < set.verts.length; i++) {
        const v = m.verts.get(set.verts[i]);
        if (v != null) v.select = true;
        else missing++;
    }
    for (let i = 0; i < set.edges.length; i++) {
        const e = m.edges.get(set.edges[i]);
        if (e != null) e.select = true;
        else missing++;
    }
    for (let i = 0; i < set.faces.length; i++) {
        const f = m.faces.get(set.faces[i]);
        if (f != null) f.select = true;
        else missing++;
    }
    flushSelection(m, ElemKind.Vert);
    // Faces/edges selected explicitly beat vert-derived deselection.
    for (let i = 0; i < set.faces.length; i++) {
        const f = m.faces.get(set.faces[i]);
        if (f != null) f.select = true;
    }
    for (let i = 0; i < set.edges.length; i++) {
        const e = m.edges.get(set.edges[i]);
        if (e != null) e.select = true;
    }
    m.touch();
    return missing;
}

// Ids of the selected elements of `kind`.
export function selectedIds(m: Mesh, kind: ElemKind): Array<u32> {
    switch (kind) {
        case ElemKind.Vert: return m.selectedVerts();
        case ElemKind.Edge: return m.selectedEdges();
        default: return m.selectedFaces();
    }
}

// Set the selection of `kind` to exactly `ids` and flush.
export function setSelection(m: Mesh, kind: ElemKind, ids: Array<u32>): void {
    m.selectAll(false);
    selectIds(m, kind, ids, true);
}
