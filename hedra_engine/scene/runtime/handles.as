// Typed handles (milestone 39): a SceneInstance's nodes as handles of the
// class that fits each, so that code reads `lamp.lightEnergy = 2` and the
// compiler checks the property. A handle knows its node's index in the
// tree's walk as it was when the handle was made (SceneInstance.nodeAt),
// and its path to check it: when the scene's structure changed since (a
// node added or removed), the path finds the node instead.
//
// Writes go through the node's own API (Godot's semantics,
// ../tree/node.as) and `touch` the instance, so the next draw shows them.
// The pinned compiler refuses an assignment through an accessor of a
// vector (error E3001), so vectors are set with methods and scalars with
// accessors.
//
// A handle whose node is gone (the index and the path both miss) reads as
// the defaults (0, false, the origin) and writes nothing.

import { Vec3, Vec4 } from "../../base/vecmath";
import { makeCameraCurrent } from "../binding/apply";
import { isA } from "../classdb";
import { Camera3D, Light3D, SceneNode } from "../tree/node";
import { viewportOf } from "../tree/viewports";
import { SceneInstance } from "./scene_runtime";

const DEG: f32 = <f32>(Math.PI / 180);

export class NodeHandle {
    instance: SceneInstance;
    index: i32;
    path: string;

    constructor(instance: SceneInstance, index: i32, path: string) {
        this.instance = instance;
        this.index = index;
        this.path = path;
    }

    // The node: nodeAt(index) when its path is `path`, else node(path).
    // (A node keeps its path unless a script renamed or moved it, so the
    // path is compared, not trusted: a handle made before the tree
    // changed finds the node by path.)
    node(): SceneNode? {
        const inst = this.instance;
        const at = inst.nodeAt(this.index);
        if (at != null && at.pathFrom(inst.tree.root) == this.path) return at;
        return inst.node(this.path);
    }

    get visible(): bool {
        const n = this.node();
        return n != null && n.visible;
    }

    set visible(v: bool) {
        const n = this.node();
        if (n == null || n.visible == v) return;
        n.visible = v;
        this.instance.touch();
    }
}

export class Node3DHandle extends NodeHandle {
    constructor(instance: SceneInstance, index: i32, path: string) {
        super(instance, index, path);
    }

    position(): Vec3 {
        const n = this.node();
        return n != null ? n.position : Vec3(0, 0, 0);
    }

    setPosition(x: f32, y: f32, z: f32): void {
        const n = this.node();
        if (n == null) return;
        n.setPosition(Vec3(x, y, z));
        this.instance.touch();
    }

    // Euler angles in degrees, YXZ (Godot's rotation_degrees).
    setRotationDegrees(x: f32, y: f32, z: f32): void {
        const n = this.node();
        if (n == null) return;
        n.setRotation(Vec3(x * DEG, y * DEG, z * DEG));
        this.instance.touch();
    }

    setScale(x: f32, y: f32, z: f32): void {
        const n = this.node();
        if (n == null) return;
        n.setScale(Vec3(x, y, z));
        this.instance.touch();
    }
}

export class LightHandle extends Node3DHandle {
    constructor(instance: SceneInstance, index: i32, path: string) {
        super(instance, index, path);
    }

    // The light, or null (gone, or not a light).
    light(): Light3D? {
        const n = this.node();
        if (n == null || !(n instanceof Light3D)) return null;
        return n as Light3D;
    }

    get lightEnergy(): f32 {
        const l = this.light();
        return l != null ? l.energy : 0;
    }

    set lightEnergy(v: f32) {
        const l = this.light();
        if (l == null) return;
        l.energy = v;
        this.instance.touch();
    }

    // sRGB, as light_color.
    setLightColor(r: f32, g: f32, b: f32): void {
        const l = this.light();
        if (l == null) return;
        l.color = Vec4(r, g, b, l.color.w);
        this.instance.touch();
    }
}

export class CameraHandle extends Node3DHandle {
    constructor(instance: SceneInstance, index: i32, path: string) {
        super(instance, index, path);
    }

    // The camera, or null (gone, or not a camera).
    camera(): Camera3D? {
        const n = this.node();
        if (n == null || !(n instanceof Camera3D)) return null;
        return n as Camera3D;
    }

    // Degrees, Godot's `fov`.
    get fov(): f32 {
        const c = this.camera();
        return c != null ? c.fov : 0;
    }

    set fov(v: f32) {
        const c = this.camera();
        if (c == null) return;
        c.fov = v;
        this.instance.touch();
    }

    // Godot's make_current, per viewport: a camera of the main view is
    // looked through (SceneInstance.setCamera with its path); one under a
    // SubViewport becomes that viewport's current camera, leaving the main
    // view's alone.
    makeCurrent(): void {
        const c = this.camera();
        if (c == null) return;
        const tree = this.instance.tree;
        if (viewportOf(c) == null) {
            this.instance.setCamera(c.pathFrom(tree.root));
            return;
        }
        makeCameraCurrent(tree, c);
        this.instance.touch();
    }
}

export class MeshHandle extends Node3DHandle {
    constructor(instance: SceneInstance, index: i32, path: string) {
        super(instance, index, path);
    }
}

// The handle class that fits a node of class `nodeClass`.
export function handleClassFor(nodeClass: string): string {
    if (isA(nodeClass, "Light3D")) return "LightHandle";
    if (isA(nodeClass, "Camera3D")) return "CameraHandle";
    if (isA(nodeClass, "MeshInstance3D") || isA(nodeClass, "ModelInstance3D")) return "MeshHandle";
    if (isA(nodeClass, "Node3D")) return "Node3DHandle";
    return "NodeHandle";
}
