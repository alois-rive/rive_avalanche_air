// PLACEHOLDER (the gameplay's owner replaces it: docs/RIDER.md, section 13).
// The run's driver: slides game.rider down the placeholder slope and writes
// two pins, to prove the contracts end to end.
import { NodeScript, SceneNode, Vec3 } from "hedra_engine/script";
import { GroundHit, ground } from "./course_api";
import { PHASE_RIDING, game } from "./game_state";
import { PIN_COUNT, PIN_PATHS, PIN_PROGRESS, PIN_SPEED_KMH } from "./pins_data";

export class Run extends NodeScript {
    rider: SceneNode? = null;
    pins: Array<SceneNode?> = new Array<SceneNode?>();
    hit: GroundHit = new GroundHit();

    _ready(): void {
        this.rider = this.getNode("LowRes/Rider");
        for (let i = 0; i < PIN_COUNT; i++) this.pins.push(this.getNode(PIN_PATHS[i]));
        game.phase = PHASE_RIDING;
    }

    _process(delta: f32): void {
        const r = game.rider;
        r.speed = Mathf.min(r.speed + 3 * delta, 18);
        r.z -= r.speed * delta;
        ground(r.x, r.z, this.hit);
        r.y = this.hit.y;
        r.s = -r.z;
        const n = this.rider;
        if (n != null) n.setPosition(Vec3(r.x, r.y, r.z));
        this.pin(PIN_SPEED_KMH, r.speed * 3.6);
        this.pin(PIN_PROGRESS, r.s / 400);
    }

    pin(i: i32, v: f32): void {
        const n = this.pins[i];
        if (n != null && n.position.x != v) n.setPosition(Vec3(v, 0, 0));
    }
}
