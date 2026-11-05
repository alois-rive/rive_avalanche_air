// The course's own effects (docs/LOOK.md, section 6), on course.rscn's
// `Fx` node:
//   - the snow that falls at dusk: an emitter kept over the lens (its
//     `emitting` is keyed by the Daylight timeline from s = 1,000);
//   - the finish's confetti: the timeline `Confetti` (two cannons' bursts),
//     played when the rider finishes (game.events, EV_FINISH; and EV_RESTART
//     puts nothing back: a one-shot emitter ends by itself);
//   - the lens flare: five flat additive discs on the line from the sun's
//     place on the screen through its centre, folded away (scale 0) when
//     the sun is behind the lens or under the terrain's ridge line.
//
// Allocation-free after _ready: a frame moves a few nodes.
import { NodeScript, SceneNode, ScriptAnimation, Vec3 } from "hedra_engine/script";
import { GroundHit, Sun, ground, sunAt } from "./course_api";
import { EVENT_RING, EV_FINISH, game } from "./game_state";

const FLARES: i32 = 5;
// each disc's place on the sun-to-centre line (1 the sun, 0 the centre, -1
// the mirror) and size (m at FLARE_DIST from the lens)
const FLARE_T: StaticArray<f32> = [1.0, 0.55, 0.2, -0.35, -0.8];
const FLARE_SIZE: StaticArray<f32> = [0.26, 0.09, 0.05, 0.12, 0.18];
const FLARE_DIST: f32 = 2.0;
const TAN_HALF_V: f32 = 0.6494;     // tan(66 deg / 2): the lens's vertical half-angle
const ASPECT: f32 = 4.0 / 3.0;

export class CourseFx extends NodeScript {
    lens: SceneNode? = null;
    snow: SceneNode? = null;
    flares: Array<SceneNode?> = new Array<SceneNode?>();
    confetti: ScriptAnimation? = null;
    cursor: i32 = 0;
    sun: Sun = new Sun();
    hit: GroundHit = new GroundHit();
    lastS: f32 = -100;

    _ready(): void {
        this.lens = this.node.getNode("../../Lens");
        this.snow = this.node.getNode("Snow");
        for (let i = 0; i < FLARES; i++) this.flares.push(this.node.getNode("Flare" + i.toString()));
        const sc = this.scene;
        if (sc != null) this.confetti = sc.animation("Confetti");
        this.cursor = game.events.written;
        sunAt(game.rider.s, this.sun);
    }

    _process(delta: f32): void {
        // the events: the finish fires the cannons
        const ev = game.events;
        if (ev.written - this.cursor > EVENT_RING) this.cursor = ev.written - EVENT_RING;
        while (this.cursor < ev.written) {
            const kind = ev.kinds[this.cursor % EVENT_RING];
            this.cursor++;
            if (kind == EV_FINISH) {
                const c = this.confetti;
                if (c != null) {
                    c.setTime(0);
                    c.play();
                }
            }
        }
        const lens = this.lens;
        if (lens == null) return;
        const eye = lens.globalPosition;
        const snow = this.snow;
        if (snow != null) snow.setPosition(Vec3(eye.x, eye.y + 14, eye.z - 10));
        if (Mathf.abs(game.rider.s - this.lastS) > 2) {
            sunAt(game.rider.s, this.sun);
            this.lastS = game.rider.s;
        }
        this.flare(lens, eye);
    }

    flare(lens: SceneNode, eye: Vec3): void {
        // the lens's axes from its rotation (Euler YXZ, as the rotation property)
        const r = lens.rotation;
        const cx = Mathf.cos(r.x);
        const sx = Mathf.sin(r.x);
        const cy = Mathf.cos(r.y);
        const sy = Mathf.sin(r.y);
        const cz = Mathf.cos(r.z);
        const sz = Mathf.sin(r.z);
        // basis = Ry * Rx * Rz, columns: right, up, back
        const rx = cy * cz + sy * sx * sz;
        const ry = cx * sz;
        const rz = -sy * cz + cy * sx * sz;
        const ux = -cy * sz + sy * sx * cz;
        const uy = cx * cz;
        const uz = sy * sz + cy * sx * cz;
        const bx = sy * cx;
        const by = -sx;
        const bz = cy * cx;
        const s = this.sun;
        // the sun in the lens's frame
        const dr = s.dirX * rx + s.dirY * ry + s.dirZ * rz;
        const du = s.dirX * ux + s.dirY * uy + s.dirZ * uz;
        const db = s.dirX * bx + s.dirY * by + s.dirZ * bz;
        let show = db < -0.2;
        let nx: f32 = 0;
        let ny: f32 = 0;
        if (show) {
            nx = (dr / -db) / (TAN_HALF_V * ASPECT);
            ny = (du / -db) / TAN_HALF_V;
            show = Mathf.abs(nx) < 1.3 && Mathf.abs(ny) < 1.3;
        }
        if (show) {
            // the sun behind a ridge: the terrain between the lens and 300 m out
            for (let k = 1; k <= 6 && show; k++) {
                const d = <f32>k * 50;
                if (ground(eye.x + s.dirX * d, eye.z + s.dirZ * d, this.hit) && this.hit.y > eye.y + s.dirY * d) show = false;
            }
        }
        for (let i = 0; i < FLARES; i++) {
            const n = this.flares[i];
            if (n == null) continue;
            if (!show) {
                n.setScale(Vec3(0.001, 0.001, 0.001));
                continue;
            }
            const t = FLARE_T[i];
            const px = nx * t * TAN_HALF_V * ASPECT * FLARE_DIST;
            const py = ny * t * TAN_HALF_V * FLARE_DIST;
            n.setPosition(Vec3(eye.x + rx * px + ux * py - bx * FLARE_DIST,
                eye.y + ry * px + uy * py - by * FLARE_DIST,
                eye.z + rz * px + uz * py - bz * FLARE_DIST));
            n.setRotation(r);
            const k = FLARE_SIZE[i];
            n.setScale(Vec3(k, k, k));
        }
    }
}
