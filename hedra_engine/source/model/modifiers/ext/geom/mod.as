// Geometry shared by more than one of this package's tools.
//
// Nothing here knows about the scene or the command language: these are
// plain functions over points and triangles, so the boolean modifier and
// the `boolean` edit operator run the same code, and so does every other
// pair that Blender exposes twice (solidify, decimate, wireframe, screw).
//
// Re-exports only; the submodules are bvh, field, hull, quadric and tri.

export { Bvh } from "./bvh";
export { Tri, closestPointOnTri, rayTri, triTriIntersect } from "./tri";
