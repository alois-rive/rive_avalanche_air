// The Triangulate modifier, every face
// becomes triangles.

import { Mesh, FaceId } from "../mesh/mod";
import { TriangulateMethod, triangulateFaces } from "../ops/triangulate_op";

export function triangulate(mesh: Mesh): Array<FaceId> {
    const faces = mesh.faces.ids();
    return triangulateFaces(mesh, faces, TriangulateMethod.Beauty);
}
