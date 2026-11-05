// Per-vertex weighting: the "Vertex Group" slot every Blender deformer
// has, plus this tool's named attributes standing in for Blender's texture
// input.
//
// Blender modulates Displace, Smooth, Cast, Simple Deform, Shrinkwrap and
// the rest by a vertex group, and Displace additionally by a texture. There
// are no textures to sample here, but there *are* named float attributes
// computed from an expression (`attribute add`), which is the same idea
// reached by a different road — so `--attribute` is where a texture would
// have gone.

import { Mesh, ElemKind } from "../../../mesh/mod";
import { AttrValue, AttrValueKind } from "../../../mesh/attr";
import { Object, NO_VGROUP } from "../../../scene";
import { clampF32, trimUnicode } from "../../../../../base/util";

// A weight per vertex in `0..=1`, the product of whatever inputs are set.
export class Field {
    // `null` means "1 everywhere", which saves a vector on the common path.
    // Indexed by VertId, `id_bound` long.
    weights: Array<f32>? = null;
    // Warnings for inputs that named something the mesh does not have.
    warnings: Array<string> = [];

    // Build from a vertex group name and an attribute name, either of which
    // may be empty or `none`. An unknown name is a warning, not an error:
    // a modifier stack that loses a vertex group should still evaluate.
    static build(mesh: Mesh, object: Object?, group: string, attribute: string): Field {
        const out = new Field();
        const bound = <i32>mesh.verts.idBound();

        const gname = named(group);
        if (gname != null) {
            let index = NO_VGROUP;
            if (object != null) index = object.vgroupIndex(gname);
            if (index != NO_VGROUP) {
                const w = ensure(out, bound);
                const ids = mesh.verts.ids();
                for (let k = 0; k < ids.length; k++) {
                    const id = ids[k];
                    const v = mesh.verts.at(id);
                    let g: f32 = 0.0;
                    for (let j = 0; j < v.groups.length; j++) {
                        if (v.groups[j].group == index) {
                            g = v.groups[j].weight;
                            break;
                        }
                    }
                    w[<i32>id] = w[<i32>id] * clampF32(g, 0.0, 1.0);
                }
            } else if (object != null) {
                out.warnings.push("no vertex group '" + gname + "'; weighting ignored");
            } else {
                out.warnings.push(
                    "vertex group '" + gname + "' needs the object, and this evaluation has none",
                );
            }
        }

        const aname = named(attribute);
        if (aname != null) {
            if (mesh.attr(aname) != null) {
                const w = ensure(out, bound);
                const ids = mesh.verts.ids();
                for (let k = 0; k < ids.length; k++) {
                    const id = ids[k];
                    const av = mesh.attrValue(aname, ElemKind.Vert, id);
                    const v: f32 = av != null ? scalar(av) : <f32>0.0;
                    w[<i32>id] = w[<i32>id] * v;
                }
            } else {
                out.warnings.push(
                    "no attribute '" + aname + "'; `attribute list` shows the ones this mesh has",
                );
            }
        }

        return out;
    }

    // Weight of one vertex. Out-of-range ids answer 1, so a caller that
    // added vertices after the field was built is not silently zeroed.
    at(v: u32): f32 {
        const w = this.weights;
        if (w == null) return 1.0;
        if (v >= <u32>w.length) return 1.0;
        return w[<i32>v];
    }

    // True when nothing modulates this field, so callers can take a fast
    // path.
    isUniform(): bool {
        return this.weights == null;
    }
}

function ensure(f: Field, bound: i32): Array<f32> {
    let w = f.weights;
    if (w == null) {
        const nw = new Array<f32>(bound);
        for (let i = 0; i < bound; i++) nw[i] = 1.0;
        f.weights = nw;
        return nw;
    }
    return w;
}

// `""` and `none` both mean "not set", matching how `modifier set` clears
// a name. Returns the trimmed name, or null.
function named(s: string): string? {
    const t = trimUnicode(s);
    if (t.length == 0 || t == "none") return null;
    return t;
}

// An attribute value as a scalar: a vector contributes its length, which is
// what `attribute convert` does when it moves a vec3 onto a float.
function scalar(v: AttrValue): f32 {
    if (v.kind == AttrValueKind.Vec3) return v.v.length();
    return <f32>v.asF64();
}
