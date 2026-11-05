// Shape keys (Blender's Key / KeyBlock,
// relative mode only). Every key stores absolute positions indexed by vertex
// id; the evaluated mesh is `basis + sum(value * (key - relative_to))`,
// applied before modifiers.
//
// Vertex coordinates (`Vert.co`) hold the Basis in object mode. While a mesh
// is edited, `co` holds the active key (Blender loads the active key into the
// edit mesh and writes it back on exit): the command layer calls
// `Mesh.storeActiveShapeKey` after every edit-mode command and
// `Mesh.loadShapeKey` when the active key or the mode changes. A vertex
// created by an operator has no entry in the keys yet; it takes its current
// `co` in every key (positions past the end of a key's list read as the
// vertex's own coordinate), so new geometry carries no offset in any key.
//
// Free functions `fn(m: Mesh, ...)`, with one-line delegating methods on
// Mesh (section "shape keys" of mod.as). Key indices are i32; -1 means none.

import { Vec3, VEC3_ZERO } from "../../../base/vecmath";
import { panic } from "../../../base/util";
import { debugF32, zeroPad } from "../../../base/fmt";
import { Mesh, VertId } from "./mod";

export class ShapeKey {
    name: string = "";
    value: f32 = 0;
    sliderMin: f32 = 0;
    sliderMax: f32 = 1;
    // Index of the key this one is relative to (Blender's `relative_key`).
    relativeTo: u32 = 0;
    mute: bool = false;
    // Absolute positions by vertex id; see the module doc for short lists.
    positions: Array<Vec3> = [];

    // A key with default settings.
    static new(name: string, positions: Array<Vec3>): ShapeKey {
        const k = new ShapeKey();
        k.name = name;
        k.positions = positions;
        return k;
    }

    // The value clamped to the slider range; panics when min > max or
    // either bound is NaN.
    clampedValue(): f32 {
        const lo = this.sliderMin;
        const hi = this.sliderMax;
        if (!(lo <= hi)) {
            panic("min > max, or either was NaN. min = " + debugF32(lo) + ", max = " + debugF32(hi));
        }
        let x = this.value;
        if (x < lo) x = lo;
        if (x > hi) x = hi;
        return x;
    }

    // A deep copy.
    clone(): ShapeKey {
        const k = new ShapeKey();
        k.name = this.name;
        k.value = this.value;
        k.sliderMin = this.sliderMin;
        k.sliderMax = this.sliderMax;
        k.relativeTo = this.relativeTo;
        k.mute = this.mute;
        k.positions = this.positions.slice(0);
        return k;
    }

    // Field-wise equality.
    equals(o: ShapeKey): bool {
        if (this.name != o.name || this.value != o.value || this.sliderMin != o.sliderMin
            || this.sliderMax != o.sliderMax || this.relativeTo != o.relativeTo || this.mute != o.mute) return false;
        if (this.positions.length != o.positions.length) return false;
        for (let i = 0; i < this.positions.length; i++) {
            if (!(this.positions[i] == o.positions[i])) return false;
        }
        return true;
    }
}

export const BASIS_NAME = "Basis";

export function hasShapeKeys(m: Mesh): bool {
    return m.shapeKeys.length != 0;
}

// Index of the key named `name`, or -1.
export function findShapeKey(m: Mesh, name: string): i32 {
    for (let i = 0; i < m.shapeKeys.length; i++) {
        if (m.shapeKeys[i].name == name) return i;
    }
    return -1;
}

// The active shape key, or null (the field `activeShapeKey` is its index).
export function activeShapeKeyOf(m: Mesh): ShapeKey? {
    const i = m.activeShapeKey;
    if (i >= <u32>m.shapeKeys.length) return null;
    return m.shapeKeys[<i32>i];
}

// Position of vertex `v` in key `key` (its `co` when the key has no entry for
// it yet).
export function shapeKeyCo(m: Mesh, key: i32, v: VertId): Vec3 {
    if (key >= 0 && key < m.shapeKeys.length) {
        const ps = m.shapeKeys[key].positions;
        if (v < <u32>ps.length) return ps[<i32>v];
    }
    return m.verts.at(v).co;
}

// The current coordinates of every vertex slot (dead slots zero).
function coTable(m: Mesh): Array<Vec3> {
    const n = <i32>m.verts.idBound();
    const out: Array<Vec3> = [];
    for (let i = 0; i < n; i++) {
        const v = m.verts.get(<u32>i);
        if (v != null) out.push(v.co);
        else out.push(VEC3_ZERO);
    }
    return out;
}

// Give every key an entry for every vertex (new vertices take their `co`).
// Called by the command layer after each command.
export function extendShapeKeys(m: Mesh): void {
    if (m.shapeKeys.length == 0) return;
    const table = coTable(m);
    for (let k = 0; k < m.shapeKeys.length; k++) {
        const ps = m.shapeKeys[k].positions;
        for (let i = ps.length; i < table.length; i++) ps.push(table[i]);
    }
}

function isAsciiDigits(s: string): bool {
    for (let i = 0; i < s.length; i++) {
        const c = s.charCodeAt(i);
        if (c < 0x30 || c > 0x39) return false;
    }
    return true;
}

// Blender-style unique key naming (`Key`, `Key.001`, ...).
export function uniqueShapeKeyName(m: Mesh, base: string): string {
    if (findShapeKey(m, base) < 0) return base;
    let stem = base;
    const i = base.lastIndexOf(".");
    if (i >= 0) {
        // The suffix is 3 ASCII digits (for ASCII digits the UTF-16 length
        // equals the UTF-8 length).
        const suffix = base.substring(i + 1);
        if (suffix.length == 3 && isAsciiDigits(suffix)) stem = base.substring(0, i);
    }
    for (let n = 1; n < 10000; n++) {
        const candidate = stem + "." + zeroPad(n, 3);
        if (findShapeKey(m, candidate) < 0) return candidate;
    }
    return stem + "." + m.shapeKeys.length.toString();
}

// Add a key named `name` (made unique) and make it active. The first call
// also creates the Basis from the mesh coordinates. The new key copies the
// basis, or the current mix with `fromMix`. Returns the index of the named key.
export function shapeKeyAdd(m: Mesh, name: string, fromMix: bool): i32 {
    if (m.shapeKeys.length == 0) {
        const basis = ShapeKey.new(BASIS_NAME, coTable(m));
        m.shapeKeys.push(basis);
        m.activeShapeKey = 0;
        if (name == BASIS_NAME) {
            m.touch();
            return 0;
        }
    }
    extendShapeKeys(m);
    const positions = fromMix ? shapeKeyMix(m) : m.shapeKeys[0].positions.slice(0);
    const unique = uniqueShapeKeyName(m, name);
    m.shapeKeys.push(ShapeKey.new(unique, positions));
    m.activeShapeKey = <u32>(m.shapeKeys.length - 1);
    m.touch();
    return m.shapeKeys.length - 1;
}

// Remove a key. Removing the Basis promotes the next key; keys relative to
// the removed one point at the basis afterwards.
export function shapeKeyRemove(m: Mesh, index: i32): void {
    if (index < 0 || index >= m.shapeKeys.length) return;
    m.shapeKeys.splice(index, 1);
    const idx = <u32>index;
    for (let i = 0; i < m.shapeKeys.length; i++) {
        const k = m.shapeKeys[i];
        const r = k.relativeTo;
        k.relativeTo = r == idx ? 0 : (r > idx ? r - 1 : r);
    }
    const len = <u32>m.shapeKeys.length;
    if (m.activeShapeKey >= len) {
        m.activeShapeKey = len > 0 ? len - 1 : 0;
    } else if (m.activeShapeKey > idx) {
        m.activeShapeKey -= 1;
    }
    m.touch();
}

// True when the object-mode shape differs from the basis: some key other
// than the basis contributes.
export function hasShapeKeyMix(m: Mesh): bool {
    for (let i = 0; i < m.shapeKeys.length; i++) {
        const k = m.shapeKeys[i];
        if (i != 0 && !k.mute && k.clampedValue() != 0 && k.relativeTo != <u32>i) return true;
    }
    return false;
}

// `basis + sum(value * (key - relative))`, indexed by vertex id.
export function shapeKeyMix(m: Mesh): Array<Vec3> {
    const n = m.verts.idBound();
    // Build this table first (so a dead slot without a basis entry panics
    // even when there are no keys), then check for keys.

    const out: Array<Vec3> = [];
    for (let v: u32 = 0; v < n; v++) out.push(shapeKeyCo(m, 0, v));
    if (m.shapeKeys.length == 0) return coTable(m);
    const last = <u32>(m.shapeKeys.length - 1);
    for (let i = 0; i < m.shapeKeys.length; i++) {
        const k = m.shapeKeys[i];
        if (i == 0 || k.mute) continue;
        const w = k.clampedValue();
        const rel = <i32>(k.relativeTo < last ? k.relativeTo : last);
        if (w == 0 || rel == i) continue;
        for (let v: u32 = 0; v < n; v++) {
            if (!m.verts.contains(v)) continue;
            const off = shapeKeyCo(m, i, v) - shapeKeyCo(m, rel, v);
            const s = out[<i32>v] + off * w;
            out[<i32>v].x = s.x;
            out[<i32>v].y = s.y;
            out[<i32>v].z = s.z;
        }
    }
    return out;
}

// Write `positions` (by vertex id) into `co` and refresh normals.
export function setAllPositions(m: Mesh, positions: Array<Vec3>): void {
    const n = m.verts.idBound();
    for (let id: u32 = 0; id < n; id++) {
        const v = m.verts.get(id);
        if (v == null) continue;
        if (id < <u32>positions.length) v.co = positions[<i32>id];
    }
    m.recalcNormals();
    m.touch();
}

// The mesh with the shape key mix applied (object-mode look).
export function withShapeKeyMix(m: Mesh): Mesh {
    const out = m.clone();
    const mix = shapeKeyMix(m);
    setAllPositions(out, mix);
    return out;
}

// The mesh with one key's absolute positions as coordinates.
export function withShapeKey(m: Mesh, key: i32): Mesh {
    const out = m.clone();
    const positions: Array<Vec3> = [];
    const n = m.verts.idBound();
    for (let v: u32 = 0; v < n; v++) positions.push(shapeKeyCo(m, key, v));
    setAllPositions(out, positions);
    return out;
}

// Copy `co` into the active key (edit mode writes the active key).
export function storeActiveShapeKey(m: Mesh): void {
    if (m.shapeKeys.length == 0) return;
    extendShapeKeys(m);
    const last = <u32>(m.shapeKeys.length - 1);
    const i = <i32>(m.activeShapeKey < last ? m.activeShapeKey : last);
    const table = coTable(m);
    const ps = m.shapeKeys[i].positions;
    const n = m.verts.idBound();
    for (let id: u32 = 0; id < n; id++) {
        if (!m.verts.contains(id)) continue;
        const c = table[<i32>id];
        ps[<i32>id].x = c.x;
        ps[<i32>id].y = c.y;
        ps[<i32>id].z = c.z;
    }
}

// Load a key's positions into `co`.
export function loadShapeKey(m: Mesh, key: i32): void {
    if (key < 0 || key >= m.shapeKeys.length) return;
    extendShapeKeys(m);
    const positions = m.shapeKeys[key].positions.slice(0);
    setAllPositions(m, positions);
}

// Object mode: an operator moved `co` (apply transform, origin set, ...)
// while `co` was the basis. Carry the same per-vertex delta into every key so
// offsets survive, then the basis is `co` again.
export function propagateBasisChange(m: Mesh): void {
    if (m.shapeKeys.length == 0) return;
    extendShapeKeys(m);
    let moved = false;
    const n = m.verts.idBound();
    for (let id: u32 = 0; id < n; id++) {
        const v = m.verts.get(id);
        if (v == null) continue;
        const d = v.co - m.shapeKeys[0].positions[<i32>id];
        if (!(d == VEC3_ZERO)) {
            moved = true;
            for (let k = 0; k < m.shapeKeys.length; k++) {
                const ps = m.shapeKeys[k].positions;
                const s = ps[<i32>id] + d;
                ps[<i32>id].x = s.x;
                ps[<i32>id].y = s.y;
                ps[<i32>id].z = s.z;
            }
        }
    }
    if (moved) m.touch();
}
