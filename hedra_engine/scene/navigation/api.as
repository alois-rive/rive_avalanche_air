// What scripts ask the scene's navigation map (milestone 63,
// docs/engine/NAVIGATION.md "Queries from scripts"): Godot's
// NavigationServer3D map queries and its path query objects, under Godot's
// names in AnimaScript's camel case, reached as Godot reaches them:
//
//   const map = this.getWorld3D().navigationMap;
//   const path = NavigationServer3D.mapGetPath(map, from, to, true);
//   for (let i = 0; i < path.length; i++) print(path[i].x.toString());
//
// Godot names a map by an RID; here the map is the object itself
// (World3D.navigationMap, NavigationAgent3D.getNavigationMap()). Godot
// answers with a PackedVector3Array; here an Array<Vec3> that belongs to
// the map and is filled again by its next query, so that a script asking
// every frame allocates nothing (the stub allocator never frees): copy what
// you keep. A NavigationPathQueryResult3D is the caller's, filled in place.
//
// The base class answers nothing: the map of a tree that no navigation
// serves (the tools' trees until a tool makes one, a scene without a
// NavigationRegion3D or NavigationLink3D). The engine's map (./map.as
// NavMap) extends it; the run time's navigation feature puts its own on the
// tree (SceneTree.world.navigationMap) for scenes that have navigation
// nodes.
//
// Spaces are scene space: Y up, metres, global coordinates.

import { Vec3 } from "../../base/vecmath";
import { SceneNode } from "../tree/node";

// Every navigation layer (Godot's default mask for a query is 1; this is
// every bit).
export const ALL_NAVIGATION_LAYERS: u32 = 0xFFFFFFFF;

// Godot's NavigationPathQueryParameters3D.PathfindingAlgorithm.
export const PATHFINDING_ALGORITHM_ASTAR: i32 = 0;

// Godot's NavigationPathQueryParameters3D.PathPostProcessing.
export const PATH_POSTPROCESSING_CORRIDORFUNNEL: i32 = 0;
export const PATH_POSTPROCESSING_EDGECENTERED: i32 = 1;
export const PATH_POSTPROCESSING_NONE: i32 = 2;

// Godot's NavigationPathQueryParameters3D.PathMetadataFlags.
export const PATH_METADATA_INCLUDE_NONE: i32 = 0;
export const PATH_METADATA_INCLUDE_TYPES: i32 = 1;
export const PATH_METADATA_INCLUDE_RIDS: i32 = 2;
export const PATH_METADATA_INCLUDE_OWNERS: i32 = 4;
export const PATH_METADATA_INCLUDE_ALL: i32 = 7;

// Godot's NavigationPathQueryResult3D.PathSegmentType: what a path point
// lies on.
export const PATH_SEGMENT_TYPE_REGION: i32 = 0;
export const PATH_SEGMENT_TYPE_LINK: i32 = 1;

// Godot's NavigationPathQueryParameters3D.
export class NavigationPathQueryParameters3D {
    map: NavigationMap? = null;
    startPosition: Vec3 = Vec3(0, 0, 0);
    targetPosition: Vec3 = Vec3(0, 0, 0);
    navigationLayers: u32 = 1;
    pathfindingAlgorithm: i32 = PATHFINDING_ALGORITHM_ASTAR;
    pathPostprocessing: i32 = PATH_POSTPROCESSING_CORRIDORFUNNEL;
    metadataFlags: i32 = PATH_METADATA_INCLUDE_ALL;
    simplifyPath: bool = false;
    simplifyEpsilon: f32 = 0;
}

// Godot's NavigationPathQueryResult3D, filled in place by a query (its
// arrays keep their storage: a query allocates nothing once they have
// grown). `pathTypes`, `pathOwners` and `pathOwnerIds` are filled when the
// query's metadataFlags ask for them, one item a point; an owner is the
// NavigationRegion3D or NavigationLink3D the point lies on, its id the
// node's serial (Godot's ObjectID).
export class NavigationPathQueryResult3D {
    path: Array<Vec3> = [];
    pathTypes: Array<i32> = [];
    pathOwners: Array<SceneNode?> = [];
    pathOwnerIds: Array<i64> = [];
    // The path's length in metres (Godot 4.4's path_length).
    pathLength: f32 = 0;
    // Hedra's: whether the target was on the polygons the path reached
    // (false: the path ends at the reachable point nearest the target, as
    // Godot's does), and how many polygons the search expanded.
    reachedTarget: bool = false;
    searched: i32 = 0;

    // Godot's reset(): empty, its storage kept.
    reset(): void {
        this.path.length = 0;
        this.pathTypes.length = 0;
        this.pathOwners.length = 0;
        this.pathOwnerIds.length = 0;
        this.pathLength = 0;
        this.reachedTarget = false;
        this.searched = 0;
    }
}

// What one query works in (an A* search's open list and costs): one per
// job worker (docs/engine/JOBS.md, rule 3), made by the map before a run.
// The base holds nothing; the engine's map's (./map.as) holds the search.
export class NavigationQueryScratch {}

// No path (shared, never changed).
const NO_PATH: Array<Vec3> = [];
const NO_SCRATCH = new NavigationQueryScratch();

// A navigation map: Godot's NavigationServer3D map, as an object. The base
// answers nothing (see the header).
export class NavigationMap {
    // Godot's map_get_iteration_id: moves with every sync that changed the
    // map (a region, a link, a transform); 0 before the first. An agent
    // whose path was found at another iteration asks again.
    iterationId(): i32 {
        return 0;
    }

    // Godot's map settings (the project's navigation/3d/* in hedra.yaml).
    cellSize(): f32 {
        return 0.25;
    }

    cellHeight(): f32 {
        return 0.25;
    }

    edgeConnectionMargin(): f32 {
        return 0.25;
    }

    linkConnectionRadius(): f32 {
        return 1.0;
    }

    useEdgeConnections(): bool {
        return true;
    }

    // Godot's map_get_path: the path from `origin` to `target` over the
    // polygons of `navigationLayers` (the corridor funnel when `optimize`,
    // else edge-centred). The array is the map's (see the header).
    getPath(origin: Vec3, target: Vec3, optimize: bool, navigationLayers: u32 = 1): Array<Vec3> {
        return NO_PATH;
    }

    // Godot's query_path: `p` answered into `r` (reset first).
    queryPath(p: NavigationPathQueryParameters3D, r: NavigationPathQueryResult3D): void {
        this.queryPathIn(NO_SCRATCH, p, r);
    }

    // queryPath in `scratch` (one of newScratch's): what a job's unit calls,
    // each worker with its own.
    queryPathIn(scratch: NavigationQueryScratch, p: NavigationPathQueryParameters3D, r: NavigationPathQueryResult3D): void {
        r.reset();
    }

    // A scratch for queryPathIn (made before a run, never inside one).
    newScratch(): NavigationQueryScratch {
        return new NavigationQueryScratch();
    }

    // Godot's map_get_closest_point: the point of the map's polygons (every
    // layer) nearest `to`; (0, 0, 0) on an empty map, as Godot's.
    getClosestPoint(to: Vec3): Vec3 {
        return Vec3(0, 0, 0);
    }

    // Godot's map_get_closest_point_normal: the up of the polygon holding
    // getClosestPoint's point; (0, 0, 0) on an empty map.
    getClosestPointNormal(to: Vec3): Vec3 {
        return Vec3(0, 0, 0);
    }

    // Godot's map_get_closest_point_owner: the NavigationRegion3D (or the
    // NavigationLink3D) owning that point; null on an empty map.
    getClosestPointOwner(to: Vec3): SceneNode? {
        return null;
    }

    // Godot's map_get_closest_point_to_segment: the point of the polygons
    // nearest the segment from `start` to `end` (where it crosses them, with
    // useCollision, else the nearest to the segment).
    getClosestPointToSegment(start: Vec3, end: Vec3, useCollision: bool = false): Vec3 {
        return Vec3(0, 0, 0);
    }

    // Godot's map_get_random_point: a point of the polygons of
    // `navigationLayers`, chosen by area when `uniformly`, else a polygon at
    // random then a point in it. Deterministic: the map's own stream,
    // seeded at its first sync (Hedra's: Godot's is the engine's random).
    getRandomPoint(navigationLayers: u32, uniformly: bool): Vec3 {
        return Vec3(0, 0, 0);
    }
}

// Godot's NavigationServer3D, the part scripts use (the map queries; the
// maps, regions, agents and links themselves are the scene's nodes, so
// Godot's region_*, agent_* and link_* calls are the nodes' properties).
export class NavigationServer3D {
    static mapGetPath(map: NavigationMap, origin: Vec3, target: Vec3, optimize: bool, navigationLayers: u32 = 1): Array<Vec3> {
        return map.getPath(origin, target, optimize, navigationLayers);
    }

    // Godot's query_path(parameters, result): the parameters' map answers.
    static queryPath(p: NavigationPathQueryParameters3D, r: NavigationPathQueryResult3D): void {
        const m = p.map;
        if (m == null) {
            r.reset();
            return;
        }
        m.queryPath(p, r);
    }

    static mapGetClosestPoint(map: NavigationMap, to: Vec3): Vec3 {
        return map.getClosestPoint(to);
    }

    static mapGetClosestPointNormal(map: NavigationMap, to: Vec3): Vec3 {
        return map.getClosestPointNormal(to);
    }

    static mapGetClosestPointOwner(map: NavigationMap, to: Vec3): SceneNode? {
        return map.getClosestPointOwner(to);
    }

    static mapGetClosestPointToSegment(map: NavigationMap, start: Vec3, end: Vec3, useCollision: bool = false): Vec3 {
        return map.getClosestPointToSegment(start, end, useCollision);
    }

    static mapGetRandomPoint(map: NavigationMap, navigationLayers: u32, uniformly: bool): Vec3 {
        return map.getRandomPoint(navigationLayers, uniformly);
    }

    static mapGetIterationId(map: NavigationMap): i32 {
        return map.iterationId();
    }

    static mapGetCellSize(map: NavigationMap): f32 {
        return map.cellSize();
    }

    static mapGetCellHeight(map: NavigationMap): f32 {
        return map.cellHeight();
    }

    static mapGetEdgeConnectionMargin(map: NavigationMap): f32 {
        return map.edgeConnectionMargin();
    }

    static mapGetLinkConnectionRadius(map: NavigationMap): f32 {
        return map.linkConnectionRadius();
    }

    static mapGetUseEdgeConnections(map: NavigationMap): bool {
        return map.useEdgeConnections();
    }
}
