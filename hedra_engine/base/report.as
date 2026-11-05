// What an operator reports back. Blender's info-bar
// line plus structured change counts, so the command layer can build the
// JSON answer.
//
// Counts are i32 (array lengths are i32 in AS); they serialize as JSON
// unsigned integers.

import { JsonValue, JsonMap } from "./json";

export class ElementCounts {
    verts: i32 = 0;
    edges: i32 = 0;
    faces: i32 = 0;

    static of(verts: i32, edges: i32, faces: i32): ElementCounts {
        const c = new ElementCounts();
        c.verts = verts;
        c.edges = edges;
        c.faces = faces;
        return c;
    }

    clone(): ElementCounts {
        return ElementCounts.of(this.verts, this.edges, this.faces);
    }

    // Field-wise equality
    equals(o: ElementCounts): bool {
        return this.verts == o.verts && this.edges == o.edges && this.faces == o.faces;
    }

    isZero(): bool {
        return this.verts == 0 && this.edges == 0 && this.faces == 0;
    }

    // {"verts":..,"edges":..,"faces":..}
    toJson(): JsonValue {
        const m = new JsonMap();
        m.insert("verts", JsonValue.fromU64(<u64>this.verts));
        m.insert("edges", JsonValue.fromU64(<u64>this.edges));
        m.insert("faces", JsonValue.fromU64(<u64>this.faces));
        return JsonValue.object(m);
    }
}

export class Changed {
    objects: Array<string> = [];
    elements: ElementCounts = new ElementCounts();

    clone(): Changed {
        const c = new Changed();
        c.objects = this.objects.slice(0);
        c.elements = this.elements.clone();
        return c;
    }

    equals(o: Changed): bool {
        return stringsEqual(this.objects, o.objects) && this.elements.equals(o.elements);
    }

    // {"objects":[..],"elements":{..}}
    toJson(): JsonValue {
        const m = new JsonMap();
        m.insert("objects", JsonValue.strArray(this.objects));
        m.insert("elements", this.elements.toJson());
        return JsonValue.object(m);
    }
}

export class OpReport {
    message: string = "";
    changed: Changed = new Changed();
    warnings: Array<string> = [];

    // A report with a message. The builders below mutate and return this
    // report, so calls chain.
    static new(message: string): OpReport {
        const r = new OpReport();
        r.message = message;
        return r;
    }

    withObjects(names: Array<string>): OpReport {
        this.changed.objects = names;
        return this;
    }

    withElements(verts: i32, edges: i32, faces: i32): OpReport {
        this.changed.elements = ElementCounts.of(verts, edges, faces);
        return this;
    }

    warn(msg: string): OpReport {
        this.warnings.push(msg);
        return this;
    }

    // True when the operator changed anything worth logging/snapshotting.
    changedAnything(): bool {
        return this.changed.objects.length > 0 || !this.changed.elements.isZero();
    }

    clone(): OpReport {
        const r = new OpReport();
        r.message = this.message;
        r.changed = this.changed.clone();
        r.warnings = this.warnings.slice(0);
        return r;
    }

    equals(o: OpReport): bool {
        return this.message == o.message && this.changed.equals(o.changed) && stringsEqual(this.warnings, o.warnings);
    }

    // {"message":..,"changed":{..},"warnings":[..]} (in this key order)

    toJson(): JsonValue {
        const m = new JsonMap();
        m.insert("message", JsonValue.str(this.message));
        m.insert("changed", this.changed.toJson());
        m.insert("warnings", JsonValue.strArray(this.warnings));
        return JsonValue.object(m);
    }
}

function stringsEqual(a: Array<string>, b: Array<string>): bool {
    if (a.length != b.length) return false;
    for (let i = 0; i < a.length; i++) {
        if (a[i] != b[i]) return false;
    }
    return true;
}

// Blender-style pluralization helper: `plural(1, "object")` -> "1 object".
export function plural(n: i64, noun: string): string {
    if (n == 1) return "1 " + noun;
    return n.toString() + " " + noun + "s";
}
