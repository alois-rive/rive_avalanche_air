// Milestone 36: where the scene's players are heard from (docs/engine/
// AUDIO.md "The listener"), Godot's rule as a scene loads (each
// listener entering the world with `current` on, or the first one to
// enter, is made current in turn): the last AudioListener3D in tree order
// whose `current` is on, else the first one, else the camera the scene is
// seen through; listeners under a SubViewport are that viewport's, not the
// scene's, as its cameras are (../tree/node.as heardListener) (a host's: the Scene3D's `camera`, else the scene's current Camera3D,
// turned by the Scene3D's yaw; the tools': the picture's camera or the
// scene's current one). Godot takes the listener's global transform
// orthonormalised (Basis::orthonormalized: Gram-Schmidt on X, then Y, then
// Z, so a scaled or skewed parent changes nothing but where it is); so
// does this. A listener faces its -Z, as a camera does. Nothing here
// allocates.

import { Vec3 } from "../../base/vecmath";
import { AudioListener3D, SceneNode, heardListener } from "../tree/node";

export class ListenerPose {
    // Where it is and its axes in the scene's space (orthonormal: right
    // +X, up +Y, back +Z; it faces -Z), and whether one was found.
    origin: Vec3 = Vec3(0, 0, 0);
    right: Vec3 = Vec3(1, 0, 0);
    up: Vec3 = Vec3(0, 1, 0);
    back: Vec3 = Vec3(0, 0, 1);
    valid: bool = false;
    // The node it is (an AudioListener3D or a Camera3D; null for a host's
    // framed default camera).
    node: SceneNode? = null;

    // `p` (a scene point) in the listener's space.
    local(p: Vec3): Vec3 {
        const d = p - this.origin;
        return Vec3(d.dot(this.right), d.dot(this.up), d.dot(this.back));
    }
}

// The listener the scene is heard from among `walked` (a tree walk, in
// tree order: walked[0] is its root), or null when it has none (its camera
// hears): Godot's rule (see the header; visibility does not count).
export function currentListener(walked: Array<SceneNode>): AudioListener3D? {
    return walked.length > 0 ? heardListener(unchecked(walked[0])) : null;
}

// The same among `listeners` (a scene's, in tree order, none under a
// SubViewport: the audio feature's list, found again when the tree's
// structure moves). Allocates nothing.
export function listenerAmong(listeners: Array<AudioListener3D>): AudioListener3D? {
    let first: AudioListener3D? = null;
    for (let i = listeners.length - 1; i >= 0; i--) {
        const l = unchecked(listeners[i]);
        if (l.current) return l;
        if (!l.heldOff) first = l;
    }
    return first;
}

// Godot's Vector3::normalized(): divided by its length, zero for zero (the
// gains' too, ./attenuation.as).
export function normalized(v: Vec3): Vec3 {
    const l2 = v.dot(v);
    if (l2 == 0) return Vec3(0, 0, 0);
    const l = Mathf.sqrt(l2);
    return Vec3(v.x / l, v.y / l, v.z / l);
}

// `out` from `node`'s global transform, orthonormalised (its scale left
// out, its axes made perpendicular as Godot's orthonormalized()). Not
// valid when the basis is degenerate (a zero scale).
export function listenerFromNode(node: SceneNode, out: ListenerPose): void {
    const g = node.global();
    const x = normalized(g.xAxis.xyz());
    const y0 = g.yAxis.xyz();
    const y = normalized(y0 - x * x.dot(y0));
    const z0 = g.zAxis.xyz();
    const z = normalized(z0 - x * x.dot(z0) - y * y.dot(z0));
    out.origin = g.wAxis.xyz();
    out.right = x;
    out.up = y;
    out.back = z;
    out.node = node;
    out.valid = x.dot(x) > 0 && y.dot(y) > 0 && z.dot(z) > 0;
}

// `out` from a camera's eye and the point it looks at, with its up, in the
// scene's space (the run time's turned camera, converted from the
// renderer's model space by the caller): back = normalize(eye - target),
// right = normalize(up x back), up = back x right. Not valid when the eye
// is the target or the up is along the view. `node` is left as it was.
export function listenerFromLook(eye: Vec3, target: Vec3, up: Vec3, out: ListenerPose): void {
    const back = normalized(eye - target);
    const right = normalized(up.cross(back));
    out.origin = eye;
    out.back = back;
    out.right = right;
    out.up = back.cross(right);
    out.valid = back.dot(back) > 0 && right.dot(right) > 0;
}
