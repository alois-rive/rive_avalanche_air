// Slot storage with ids that never move.
//
// Elements are addressed by a u32 that is the index of their slot. Removing
// an element leaves a hole; ids are never reused, so `select face 12` keeps
// meaning for the lifetime of a mesh and `inspect` output stays stable.
// Iteration is dense over the occupied slots, in ascending id order.
//
// T must be a reference type (a class or string): holes are `null`. rasc
// structs cannot be generic arguments, so a SlotVec of vectors holds a class.
//
//   s.push(v)                      -> id
//   s.get(id): T?            the same object: mutate it in place
//   s.at(id)                       panics "dangling element id" on a hole
//   s.len() / s.idBound()          occupied count / one past the largest id
//   s.ids(), s.values(), or the allocation-free loop:
//     for (let id: u32 = 0; id < s.idBound(); id++) {
//         const v = s.get(id); if (v == null) continue; ...
//     }
//   s.map<U>(f)                    keeps ids and holes

import { panic } from "./util";

export class SlotVec<T> {
    // Occupied slots hold the element, holes hold null. Public for the
    // postcard codec (a sequence of optional elements, then `live`); do not
    // edit directly.
    slots: Array<T?> = [];
    live: u32 = 0;

    static withCapacity<T>(n: i32): SlotVec<T> {
        return new SlotVec<T>();
    }

    // Rebuilds a SlotVec from decoded slots, keeping every hole.
    static fromSlots<T>(slots: Array<T?>, live: u32): SlotVec<T> {
        const s = new SlotVec<T>();
        s.slots = slots;
        s.live = live;
        return s;
    }

    // Reserve room for `n` more entries (a no-op here).
    reserve(n: i32): void {}

    // Number of live elements.
    len(): i32 {
        return <i32>this.live;
    }

    isEmpty(): bool {
        return this.live == 0;
    }

    // One past the highest id ever handed out.
    idBound(): u32 {
        return <u32>this.slots.length;
    }

    push(value: T): u32 {
        const id = <u32>this.slots.length;
        this.slots.push(value);
        this.live += 1;
        return id;
    }

    get(id: u32): T? {
        if (id >= <u32>this.slots.length) return null;
        return this.slots[<i32>id];
    }

    contains(id: u32): bool {
        return this.get(id) != null;
    }

    // The element, or a panic on a hole or an out-of-range id.
    at(id: u32): T {
        const v = this.get(id);
        if (v == null) panic("dangling element id");
        return v!;
    }

    // Replaces the element in an occupied slot.

    set(id: u32, value: T): void {
        if (this.get(id) == null) panic("dangling element id");
        this.slots[<i32>id] = value;
    }

    remove(id: u32): T? {
        if (id >= <u32>this.slots.length) return null;
        const taken = this.slots[<i32>id];
        if (taken != null) {
            this.slots[<i32>id] = null;
            this.live -= 1;
        }
        return taken;
    }

    // Occupied ids in ascending order.
    ids(): Array<u32> {
        const out: Array<u32> = [];
        for (let i = 0; i < this.slots.length; i++) {
            if (this.slots[i] != null) out.push(<u32>i);
        }
        return out;
    }

    // Occupied elements in ascending id order.
    values(): Array<T> {
        const out: Array<T> = [];
        for (let i = 0; i < this.slots.length; i++) {
            const v = this.slots[i];
            if (v != null) out.push(v);
        }
        return out;
    }

    // Convert every element, keeping ids and holes exactly as they are.
    map<U>(f: (v: T) => U): SlotVec<U> {
        const out = new SlotVec<U>();
        const slots: Array<U?> = [];
        for (let i = 0; i < this.slots.length; i++) {
            const v = this.slots[i];
            if (v == null) slots.push(null);
            else slots.push(f(v));
        }
        out.slots = slots;
        out.live = this.live;
        return out;
    }

    clear(): void {
        this.slots = [];
        this.live = 0;
    }
}
