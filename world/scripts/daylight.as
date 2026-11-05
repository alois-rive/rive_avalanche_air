// The sunset (docs/LOOK.md, section 3; docs/COURSE.md, section 7), on the
// course scene's root: the time of day follows the rider's progress. The
// course generator keys the timeline `Daylight` (1 s long, a key at each of
// COURSE.md's keyframes, s / COURSE_LENGTH of the second) on every PSX
// material's sun, sky ambient and snow bounce, the sky's gradient and sun,
// and the Environment's fog; this script scrubs it to game.rider.s, and
// keeps the sky's sphere on the lens.
//
// Allocation-free: a frame sets one playhead and one position.
import { NodeScript, SceneNode, ScriptAnimation, Vec3 } from "hedra_engine/script";
import { COURSE_LENGTH } from "./course_api";
import { game } from "./game_state";

export class Daylight extends NodeScript {
    anim: ScriptAnimation? = null;
    sky: SceneNode? = null;
    lens: SceneNode? = null;
    shown: f32 = -1;

    _ready(): void {
        const sc = this.scene;
        if (sc != null) this.anim = sc.animation("Daylight");
        this.sky = this.node.getNode("Sky");
        this.lens = this.node.getNode("../Lens");
        this.show(game.rider.s);
    }

    _process(delta: f32): void {
        const s = game.rider.s;
        // a quarter of a metre is far below a visible change of the light
        if (Mathf.abs(s - this.shown) > 0.25) this.show(s);
        const lens = this.lens;
        const sky = this.sky;
        if (lens != null && sky != null) sky.setPosition(lens.globalPosition);
    }

    show(s: f32): void {
        const anim = this.anim;
        if (anim == null) return;
        let t = s / COURSE_LENGTH;
        if (t < 0) t = 0;
        if (t > 1) t = 1;
        anim.setTimePercentage(t);
        this.shown = s;
    }
}
