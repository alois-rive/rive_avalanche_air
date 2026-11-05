// Operators, one per file. Each is a plain function
// over the scene (or the mesh) that returns an `OpReport`; the command layer
// only parses and calls. Object-mode operators refuse to run in edit mode and
// vice versa, like Blender.
//
// There is no re-export list here: import each operator from its own
// module (`engine/src/commands/ops/add`, …). This file holds the shared helpers: the
// mode guards, `editMesh*`, `selectionKind`,
// `nothingSelected`, `requireSelected`, `meshReport`, `Rng` and `globMatch`.

import { Result } from "../../../base/util";
import { debugTuple } from "../../../base/fmt";
import { CoreError } from "../../../base/error";
import { OpReport } from "../../../base/report";
import { Mesh, ElemKind } from "../mesh/mod";
import { Scene, Mode, modeName } from "../scene";

// Most object operators refuse to run in edit mode, like Blender.
export function requireObjectMode(scene: Scene, what: string): Result<bool> {
    if (scene.mode == Mode.Object) return Result.okv<bool>(true);
    return Result.failWith<bool>(CoreError.wrongMode(what, "object", modeName(scene.mode)));
}

export function requireEditMode(scene: Scene, what: string): Result<bool> {
    if (scene.mode == Mode.Edit) return Result.okv<bool>(true);
    return Result.failWith<bool>(CoreError.wrongMode(what, "edit", modeName(scene.mode)));
}

// The active object's mesh in edit mode (the mesh every edit-mode operator
// works on).
export function editMesh(scene: Scene, what: string): Result<Mesh> {
    const r = requireEditMode(scene, what);
    if (!r.ok) return r.forward<Mesh>();
    const a = scene.requireActive();
    if (!a.ok) return a.forward<Mesh>();
    const m = scene.objects.at(a.value).mesh();
    if (m == null) return Result.failWith<Mesh>(CoreError.invalidArgument("the active object is not a mesh"));
    return Result.okv<Mesh>(m);
}

// Same as `editMesh`, for callers that only read the mesh.
export function editMeshRef(scene: Scene, what: string): Result<Mesh> {
    return editMesh(scene, what);
}

// Id of the object being edited.
export function editObject(scene: Scene, what: string): Result<u32> {
    const r = requireEditMode(scene, what);
    if (!r.ok) return r.forward<u32>();
    return scene.requireActive();
}

// The element kind operators read for the scene's select mode.
export function selectionKind(scene: Scene): ElemKind {
    return Mesh.primaryKind(scene.selectMode);
}

// Error for an empty edit-mode selection, with the hint agents need.
export function nothingSelected(kind: ElemKind): CoreError {
    return CoreError.nothingSelected(
        "`select " + ElemKind.name(kind) + " <ids>`, `select all` or `select where \"...\"` first",
    );
}

// Selected ids of `kind` (ascending), or a `NothingSelected` error.
export function requireSelected(mesh: Mesh, kind: ElemKind): Result<Array<u32>> {
    const ids = mesh.selectedIds(kind);
    if (ids.length == 0) return Result.failWith<Array<u32>>(nothingSelected(kind));
    return Result.okv<Array<u32>>(ids);
}

// Report helper: message plus the mesh's element counts.
export function meshReport(message: string, mesh: Mesh): OpReport {
    return OpReport.new(message).withElements(mesh.verts.len(), mesh.edges.len(), mesh.faces.len());
}

// A small deterministic PRNG (splitmix64) for randomize-style operators;
// seeded from `--seed` (global or per command) so replays match.
export class Rng {
    state: u64;

    constructor(seed: u64) {
        this.state = seed + 0x9E3779B97F4A7C15;
    }

    nextU64(): u64 {
        this.state += 0x9E3779B97F4A7C15;
        let z = this.state;
        z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) * 0x94D049BB133111EB;
        return z ^ (z >> 31);
    }

    // Uniform in [0, 1).
    nextF32(): f32 {
        return <f32>(this.nextU64() >> 40) / <f32>16777216.0;
    }

    // Uniform in [-1, 1).
    nextSigned(): f32 {
        return this.nextF32() * <f32>2.0 - <f32>1.0;
    }

    clone(): Rng {
        const r = new Rng(0);
        r.state = this.state;
        return r;
    }

    // Debug text: `Rng(<state>)`.
    debug(): string {
        return debugTuple("Rng", [this.state.toString()]);
    }
}

// Unicode scalar values of `s`.
function chars(s: string): Array<i32> {
    const out: Array<i32> = [];
    let i = 0;
    while (i < s.length) {
        const c = s.codePointAt(i);
        out.push(c);
        i += c > 0xFFFF ? 2 : 1;
    }
    return out;
}

// A recursive matcher `go(p, t)` would recurse once per character (and
// branch on every `*`), which overflows the wasm stack on a name of a few
// thousand characters. This decides the same language without recursion: the
// classic wildcard scan that, on a mismatch, retries from the last `*` with
// one more character swallowed. A `*` in the pattern is always the wildcard,
// `?` is exactly one character, anything else must be equal. It agrees with
// the recursive definition on every input (tests/core/ops_common_object_test.as
// checks it against `go` on every pattern/text pair up to length 5 over a
// small alphabet).
function globScan(p: Array<i32>, t: Array<i32>): bool {
    let pi = 0;
    let ti = 0;
    let star = -1; // index in p of the last `*` seen
    let mark = 0; // index in t where that `*` started matching
    while (ti < t.length) {
        if (pi < p.length && p[pi] == 0x2A) {
            // '*': try matching the empty run first.
            star = pi;
            mark = ti;
            pi++;
        } else if (pi < p.length && (p[pi] == 0x3F || p[pi] == t[ti])) {
            // '?' or the same character.
            pi++;
            ti++;
        } else if (star >= 0) {
            // Let the last `*` swallow one more character.
            pi = star + 1;
            mark++;
            ti = mark;
        } else {
            return false;
        }
    }
    // The text is used up: only `*`s may remain.
    while (pi < p.length && p[pi] == 0x2A) pi++;
    return pi == p.length;
}

// Minimal glob: `*` matches any run, `?` one character. Case-sensitive, over
// Unicode scalar values.
export function globMatch(pattern: string, text: string): bool {
    return globScan(chars(pattern), chars(text));
}
