// Godot's Debug > Visible Collision Shapes (milestone 31): every enabled
// shape of a world and every RayCast3D drawn as lines over a frame, for
// the CLI's `render --shapes` (engine/src/authoring/render/scene_renderer.as) and
// Play's --shapes (the run time's interaction feature, afterPlan). Shapes
// in Godot's debug shape colour, a hovered object's (the pointer over it)
// in the editor's highlight colour; a ray from its origin to its target in
// its debug_shape_custom_color (black: the shape colour), up to its hit in
// the contact colour when it hits, debug_shape_thickness pixels wide.
// Depth-tested (the frame's world lines), as Godot draws them.
//
// A ray is cast here, through the world's castRay with the RayCast3D's own
// parameters, rather than read from the node's last answer: a tool's tree
// (render, the editor) never runs the feature that casts it, and still
// draws where it hits. A disabled ray is drawn whole, hitting nothing (it
// casts nothing). Lines are set in place in `out` (lines.as's
// convention), so drawing a frame again allocates nothing once `out` has
// grown.

import { Vec3, Vec4 } from "../../base/vecmath";
import { lin } from "../../render/colors";
import { LineInstance } from "../../render/gpu/layouts";
import { SCENE_TO_MODEL, sceneToModel } from "../space";
import { CollisionObject3D, RayCast3D, SceneNode } from "../tree/node";
import { DEBUG_CONTACT_COLOR, DEBUG_SHAPE_COLOR, segmentInto, shapeLinesInto } from "./lines";
import { InteractionWorld, WorldRayHit } from "./world";

// The editor's gizmo highlight colour (editor/src/scene/gizmo.as
// gizmoHighlight, sRGB), for the object the pointer is over.
export const DEBUG_HOVER_COLOR: Vec4 = Vec4(1.0, 0.85, 0.3, 1.0);

// A shape's lines are 2 pixels wide, as Godot's.
const SHAPE_LINE_WIDTH: f32 = 2;

// The colours, linear (lin runs powf: worked out once).
let shapeColour: Vec4 = Vec4(0, 0, 0, 0);
let hoverColour: Vec4 = Vec4(0, 0, 0, 0);
let contactColour: Vec4 = Vec4(0, 0, 0, 0);
let coloursReady = false;

function ready(): void {
    if (coloursReady) return;
    shapeColour = linear(DEBUG_SHAPE_COLOR);
    hoverColour = linear(DEBUG_HOVER_COLOR);
    contactColour = linear(DEBUG_CONTACT_COLOR);
    coloursReady = true;
}

function linear(c: Vec4): Vec4 {
    return lin(Vec3(c.x, c.y, c.z), c.w);
}

// What a ray's cast keeps (nothing allocated per frame).
const rayHit = new WorldRayHit();
const rayExclude = new Array<SceneNode>();

// Writes the world's lines into `out` from `at` (lines.as's convention:
// set in place, pushed past the end); returns the index after the last.
// `hovered`: the object drawn highlighted (null: none). `scale`: device
// pixels a point (line widths are scaled by it).
export function debugLinesInto(world: InteractionWorld, hovered: CollisionObject3D?, scale: f32,
    out: Array<LineInstance>, at: i32): i32 {
    ready();
    let k = at;
    const es = world.entries;
    const width = SHAPE_LINE_WIDTH * scale;
    for (let i = 0; i < es.length; i++) {
        const e = unchecked(es[i]);
        if (e.disabled) continue;
        const colour = hovered != null && e.object === hovered ? hoverColour : shapeColour;
        k = shapeLinesInto(e.shape!, SCENE_TO_MODEL * e.world, colour, width, out, k);
    }
    const rays = world.rays;
    for (let i = 0; i < rays.length; i++) k = rayLinesInto(world, unchecked(rays[i]), scale, out, k);
    return k;
}

// One RayCast3D: its segment, and the part up to its hit in the contact
// colour.
function rayLinesInto(world: InteractionWorld, r: RayCast3D, scale: f32, out: Array<LineInstance>, at: i32): i32 {
    const g = r.global();
    const from = g.wAxis.truncate();
    const to = g.transformPoint3(r.targetPosition);
    const c = r.debugColor;
    const colour = c.x == 0 && c.y == 0 && c.z == 0 ? shapeColour : lin(Vec3(c.x, c.y, c.z), c.w);
    const width = <f32>max<i32>(r.debugThickness, 1) * scale;
    let hit = false;
    if (r.enabled) {
        const ex = rayExclude;
        ex.length = 0;
        for (let i = 0; i < r.exceptions.length; i++) ex.push(unchecked(r.exceptions[i]));
        const p = r.parent;
        if (r.excludeParent && p != null) {
            const isObject = p instanceof CollisionObject3D;
            if (isObject) ex.push(p);
        }
        hit = world.castRay(from, to, r.collisionMask, r.collideWithBodies, r.collideWithAreas, r.hitFromInside,
            r.hitBackFaces, ex, false, rayHit);
    }
    const a = sceneToModel(from);
    const b = sceneToModel(to);
    if (!hit) return segmentInto(a, b, colour, width, out, at);
    const m = sceneToModel(rayHit.position);
    const k = segmentInto(a, m, contactColour, width, out, at);
    return segmentInto(m, b, colour, width, out, k);
}
