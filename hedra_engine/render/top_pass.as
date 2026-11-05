// Which items the renderer draws in its top pass (milestone 16, Godot's
// `no_depth_test`): a DrawItem with `noDepthTest` is drawn after every
// other surface of the main pass, alpha-blended and without the depth test
// or write, so nothing hides it, and last in the id pass the same way, so
// its selection outline shows over everything (gpu/renderer.as runs both,
// with pipelines.as `topPipelines`). Kept apart from the GPU code so the
// rule can be tested on the CPU, and so picking (pick.as) and the renderer
// read one answer.
//
// An instanced item (a MultiMeshInstance3D) ignores the flag: its copies
// would need instanced top pipelines, and Godot's MultiMesh has no such
// property of its own (its material's flag is not modelled here). An item
// without a mesh draws nothing anywhere.

import { DrawItem } from "./frame";

// Whether the top pass draws `d` (when the host made its pipelines; else
// `d` is drawn depth-tested with the other surfaces, as before).
export function isTopItem(d: DrawItem): bool {
    return d.noDepthTest && d.instances == null && d.mesh != null;
}
