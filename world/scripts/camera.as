// PLACEHOLDER (the gameplay's owner replaces it: docs/SPEC.md, section 7).
// The lens: follows game.rider from behind and above.
import { NodeScript, Vec3 } from "hedra_engine/script";
import { game } from "./game_state";

export class ChaseCamera extends NodeScript {
    _process(delta: f32): void {
        const r = game.rider;
        this.node.setPosition(Vec3(r.x, r.y + 2.2, r.z + 5));
    }
}
