// What scripts query the scene's collision shapes with (milestone 31,
// docs/formats/RSCN.md "Interaction"): Godot's PhysicsDirectSpaceState3D
// and its query parameters, under Godot's names in AnimaScript's camel
// case, reached as Godot reaches them:
//
//   const space = this.getWorld3D().directSpaceState;
//   const q = PhysicsRayQueryParameters3D.create(from, to);
//   const hit = space.intersectRay(q);          // the nearest hit, or null
//   if (hit != null) print(hit.collider!.name + " at " + hit.position.y.toString());
//
// Godot answers with a Dictionary, which AnimaScript does not have: here a
// result is a class with the dictionary's keys as fields (`position`,
// `normal`, `collider`, `shape`, `face_index` as `faceIndex`). A result
// belongs to the space and is filled again by its next query, so a script
// that queries every frame allocates nothing (the stub allocator never
// frees): copy what you keep.
//
// The space a scene's tree has (SceneTree.world) answers nothing until
// the run time's interaction feature puts its own in
// (../runtime/feature_interaction.as, ./world.as InteractionWorld), which
// it does for a scene that has collision objects or rays: a scene without
// any has nothing to hit.
//
// Spaces are scene space: Y up, metres, global coordinates.

import { Vec3 } from "../../base/vecmath";
import { SceneNode } from "../tree/node";
import { NavigationMap } from "../navigation/api";

// Every layer: a query's default mask, as Godot's (0xFFFFFFFF).
export const ALL_LAYERS: u32 = 0xFFFFFFFF;

// Godot's PhysicsRayQueryParameters3D.
export class PhysicsRayQueryParameters3D {
    from: Vec3 = Vec3(0, 0, 0);
    to: Vec3 = Vec3(0, 0, 0);
    collisionMask: u32 = ALL_LAYERS;
    // Collision objects never hit (Godot's RIDs; here the nodes).
    exclude: Array<SceneNode> = [];
    collideWithBodies: bool = true;
    collideWithAreas: bool = false;
    hitFromInside: bool = false;
    hitBackFaces: bool = true;

    // Godot's PhysicsRayQueryParameters3D.create: a new query (make it
    // once and change its fields to query again without allocating).
    static create(from: Vec3, to: Vec3, collisionMask: u32 = ALL_LAYERS,
        exclude: Array<SceneNode>? = null): PhysicsRayQueryParameters3D {
        const q = new PhysicsRayQueryParameters3D();
        q.from = from;
        q.to = to;
        q.collisionMask = collisionMask;
        if (exclude != null) q.exclude = exclude;
        return q;
    }
}

// Godot's PhysicsPointQueryParameters3D.
export class PhysicsPointQueryParameters3D {
    position: Vec3 = Vec3(0, 0, 0);
    collisionMask: u32 = ALL_LAYERS;
    exclude: Array<SceneNode> = [];
    collideWithBodies: bool = true;
    collideWithAreas: bool = false;
}

// intersectRay's answer: Godot's dictionary's keys. `collider` is the
// CollisionObject3D hit, `shape` the index of its CollisionShape3D among
// its shape children (Godot's shape index), `faceIndex` the triangle of a
// ConcavePolygonShape3D hit (-1 for any other shape). `normal` is zero for
// a ray that started inside the shape (hitFromInside).
export class PhysicsRayResult {
    position: Vec3 = Vec3(0, 0, 0);
    normal: Vec3 = Vec3(0, 0, 0);
    collider: SceneNode? = null;
    shape: i32 = -1;
    faceIndex: i32 = -1;
}

// One of intersectPoint's answers.
export class PhysicsPointResult {
    collider: SceneNode? = null;
    shape: i32 = -1;
}

// No point found (shared, never changed).
const NO_POINTS: Array<PhysicsPointResult> = [];

// Godot's PhysicsDirectSpaceState3D. The base answers nothing: the space
// of a tree that no interaction world serves.
export class PhysicsDirectSpaceState3D {
    // The nearest shape the ray from q.from to q.to meets, or null. The
    // result is the space's own (see the header).
    intersectRay(q: PhysicsRayQueryParameters3D): PhysicsRayResult? {
        return null;
    }

    // The shapes holding q.position, at most `maxResults` (Godot's default
    // 32), in the tree order of their collision objects. The array and its results
    // are the space's own (see the header). A ConcavePolygonShape3D has no
    // inside and never holds a point, as in Godot.
    intersectPoint(q: PhysicsPointQueryParameters3D, maxResults: i32 = 32): Array<PhysicsPointResult> {
        return NO_POINTS;
    }
}

// Godot's World3D: what a scene's nodes share; here its space and
// (milestone 63) its navigation map (../navigation/api.as), which answers
// nothing until the run time's navigation feature puts its own in.
export class World3D {
    directSpaceState: PhysicsDirectSpaceState3D = new PhysicsDirectSpaceState3D();
    navigationMap: NavigationMap = new NavigationMap();
}
