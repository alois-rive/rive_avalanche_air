// The rider as drawn (docs/RIDER.md, section 12; LOOK.md, section 5): the
// Body node placed between the model's last two ticks, its 15 joints posed
// by blending the pose table (lib/poses_data.as, tools/make_poses.py) by
// the rider's state, mirrored riding switch; the blob shadow laid on the
// snow under the board; the spray, the landing's burst and the perfect
// landing's sparkle; the respawn's screen-door blink and the colour
// scheme, through the rider scene's timelines (Door, Lift, Scheme).
//
// Every node is looked up once; a missing one (the placeholder rider) is
// skipped.
import { CPUParticles3D, Mat4, SceneNode, ScriptAnimation, ScriptScene, Vec3, Vec4 } from "hedra_engine/script";
import { GroundHit, ground } from "../course_api";
import {
    EV_CRASH, EV_LAND, EV_PERFECT, GRAB_INDY, GRAB_MELON, GRAB_METHOD, GRAB_MUTE, GRAB_NONE, game,
} from "../game_state";
import { MODE_AIR, MODE_GRIND, MODE_GROUND, MODE_TUMBLE, Rider } from "../rider";
import { DEG, DrawnPose, approach, clampf } from "./kinematic";
import { Q } from "./quat";
import {
    HIPS_REST_X, HIPS_REST_Y, HIPS_REST_Z, JOINT_COUNT, JOINT_MIRROR, JOINT_PATHS, POSES, POSE_ABSORB, POSE_AIR,
    POSE_CARVE_HEEL, POSE_CARVE_TOE, POSE_CELEBRATE, POSE_CROUCH, POSE_FLAIL_A, POSE_FLAIL_B, POSE_FLIP_TUCK,
    POSE_GRIND_LEFT, POSE_GRIND_RIGHT, POSE_INDY, POSE_MELON, POSE_METHOD, POSE_MUTE, POSE_STAND, POSE_STRIDE,
    POSE_TUCK, POSE_WOBBLE,
} from "./poses_data";

const BLINK_HZ: f32 = 8;
const SHADOW_LIFT_HEIGHT: f32 = 6;

export class RiderView {
    root: SceneNode? = null;
    body: SceneNode? = null;
    shadow: SceneNode? = null;
    spray: SceneNode? = null;
    burst: SceneNode? = null;
    sparkle: SceneNode? = null;
    joints: Array<SceneNode?> = [];
    scene: ScriptScene? = null;
    door: ScriptAnimation? = null;
    lift: ScriptAnimation? = null;
    scheme: ScriptAnimation? = null;
    private schemeShown: i32 = -1;
    private doorShown: f32 = -1;
    private cur: StaticArray<f32> = new StaticArray<f32>(POSE_STRIDE);
    private tmp: StaticArray<f32> = new StaticArray<f32>(POSE_STRIDE);
    private out: StaticArray<f32> = new StaticArray<f32>(POSE_STRIDE);
    // eased layer weights
    private airW: f32 = 0;
    private grabW: f32 = 0;
    private grabPose: i32 = POSE_INDY;
    private flipW: f32 = 0;
    private grindW: f32 = 0;
    private flailW: f32 = 0;
    private celebrateW: f32 = 0;
    private q: Q = new Q();
    private hit: GroundHit = new GroundHit();
    private cursor: i32 = 0;
    private time: f32 = 0;
    celebrate: bool = false;

    // The rider scene's root (LowRes/Rider) and its scene's timelines.
    bind(root: SceneNode?, scene: ScriptScene?): void {
        this.root = root;
        if (root == null) return;
        this.body = root.getNode("Body");
        this.shadow = root.getNode("Shadow");
        this.spray = root.getNode("Spray");
        this.burst = root.getNode("Burst");
        this.sparkle = root.getNode("Sparkle");
        const body = this.body;
        for (let i = 0; i < JOINT_COUNT; i++) this.joints.push(body != null ? body.getNode(JOINT_PATHS[i]) : null);
        this.scene = scene;
        if (scene != null) {
            this.door = scene.animation("Door");
            this.lift = scene.animation("Lift");
            this.scheme = scene.animation("Scheme");
        }
        this.cursor = game.events.written;
    }

    // A cut: nothing eased from before (a restart, a respawn).
    snap(): void {
        this.airW = 0;
        this.grabW = 0;
        this.flipW = 0;
        this.grindW = 0;
        this.flailW = 0;
        this.celebrateW = 0;
    }

    draw(r: Rider, p: DrawnPose, dt: f32, schemeIndex: i32): void {
        this.time += dt;
        this.events();
        const body = this.body;
        // the body: the drawn pose, rolled into a carve by part of its edge
        const q = this.q;
        q.set(p.oqx, p.oqy, p.oqz, p.oqw);
        if (r.mode == MODE_GROUND && r.edge != 0) q.turnLocal(0, 0, 1, -r.edge * 0.45 * (r.switchStance ? -1 : 1));
        if (body != null) {
            const x2 = q.x + q.x;
            const y2 = q.y + q.y;
            const z2 = q.z + q.z;
            const xx = q.x * x2;
            const yy = q.y * y2;
            const zz = q.z * z2;
            const xy = q.x * y2;
            const xz = q.x * z2;
            const yz = q.y * z2;
            const wx = q.w * x2;
            const wy = q.w * y2;
            const wz = q.w * z2;
            body.local = Mat4(
                Vec4(1 - (yy + zz), xy + wz, xz - wy, 0),
                Vec4(xy - wz, 1 - (xx + zz), yz + wx, 0),
                Vec4(xz + wy, yz - wx, 1 - (xx + yy), 0),
                Vec4(p.ox, p.oy, p.oz, 1),
            );
        }
        this.pose(r, dt);
        this.drawShadow(r, p);
        this.drawSpray(r, p);
        // the respawn's blink: 0 and 0.75 at 8 Hz
        let door: f32 = 0;
        if (r.blinking()) door = (<i32>(this.time * BLINK_HZ * 2) & 1) == 0 ? <f32>0.75 : <f32>0;
        const d = this.door;
        if (d != null && door != this.doorShown) {
            d.setTime(door);
            this.doorShown = door;
        }
        const s = this.scheme;
        if (s != null && schemeIndex != this.schemeShown) {
            s.setTimeFrames(<f32>schemeIndex);
            this.schemeShown = schemeIndex;
        }
    }

    // ---- the poses ---------------------------------------------------------------

    private copyPose(dst: StaticArray<f32>, pose: i32): void {
        const base = pose * POSE_STRIDE;
        for (let i = 0; i < POSE_STRIDE; i++) dst[i] = POSES[base + i];
    }

    private mixPose(dst: StaticArray<f32>, pose: i32, w: f32): void {
        if (w <= 0) return;
        const k = w > 1 ? <f32>1 : w;
        const base = pose * POSE_STRIDE;
        for (let i = 0; i < POSE_STRIDE; i++) dst[i] += (POSES[base + i] - dst[i]) * k;
    }

    private pose(r: Rider, dt: f32): void {
        const cur = this.cur;
        const mode = r.mode;
        // the layers' weights, eased
        this.airW = approach(this.airW, mode == MODE_AIR ? 1 : 0, dt * 8);
        const grabPose = grabToPose(r.grab);
        if (grabPose >= 0) this.grabPose = grabPose;
        this.grabW = mode == MODE_AIR ? r.grabBlend : approach(this.grabW, 0, dt * 8);
        const flipping = mode == MODE_AIR && Mathf.abs(r.flipRate) > 60;
        this.flipW = approach(this.flipW, flipping ? 1 : 0, dt * 7);
        this.grindW = approach(this.grindW, mode == MODE_GRIND ? 1 : 0, dt * 10);
        this.flailW = approach(this.flailW, mode == MODE_TUMBLE ? 1 : 0, dt * 12);
        this.celebrateW = approach(this.celebrateW, this.celebrate && mode == MODE_GROUND ? 1 : 0, dt * 3);
        // the base: standing, leaning into the carve, tucked, crouched
        this.copyPose(cur, POSE_STAND);
        const lean = game.rider.lean;
        if (mode == MODE_GROUND) {
            if (lean > 0) this.mixPose(cur, POSE_CARVE_TOE, lean * 1.4);
            else if (lean < 0) this.mixPose(cur, POSE_CARVE_HEEL, -lean * 1.4);
        }
        this.mixPose(cur, POSE_TUCK, r.tuck);
        this.mixPose(cur, POSE_CROUCH, r.crouch);
        if (r.absorb > 0) {
            const t = r.absorb / 0.35;
            const k = clampf(r.absorbImpact / 8, 0.3, 1);
            this.mixPose(cur, POSE_ABSORB, Mathf.sin(t * 3.14159) * k);
        }
        if (r.wobble > 0) this.mixPose(cur, POSE_WOBBLE, clampf(r.wobble / 0.25, 0, 1));
        // the air
        this.mixPose(cur, POSE_AIR, this.airW);
        this.mixPose(cur, this.grabPose, this.grabW);
        this.mixPose(cur, POSE_FLIP_TUCK, this.flipW * (1 - this.grabW * 0.5));
        // the rail: a blend between leaning left and right by the balance
        if (this.grindW > 0) {
            const tmp = this.tmp;
            this.copyPose(tmp, POSE_GRIND_LEFT);
            this.mixPose(tmp, POSE_GRIND_RIGHT, (r.grind.balance + 1) * 0.5);
            const k = this.grindW;
            for (let i = 0; i < POSE_STRIDE; i++) cur[i] += (tmp[i] - cur[i]) * k;
        }
        this.mixPose(cur, r.tumble.variant == 0 ? POSE_FLAIL_A : POSE_FLAIL_B, this.flailW);
        if (this.flailW > 0.01) {
            // flailing: the arms windmill
            const w = this.time * 9;
            cur[3 * 3 + 2] += Mathf.sin(w) * 0.8 * this.flailW;
            cur[6 * 3 + 2] += Mathf.cos(w * 1.3) * 0.8 * this.flailW;
        }
        this.mixPose(cur, POSE_CELEBRATE, this.celebrateW);
        // riding switch: left and right swapped, mirrored across the body's middle
        const out = this.out;
        if (r.switchStance) {
            for (let j = 0; j < JOINT_COUNT; j++) {
                const m = JOINT_MIRROR[j];
                out[j * 3] = -cur[m * 3];
                out[j * 3 + 1] = -cur[m * 3 + 1];
                out[j * 3 + 2] = cur[m * 3 + 2];
            }
            const o = JOINT_COUNT * 3;
            out[o] = cur[o];
            out[o + 1] = cur[o + 1];
            out[o + 2] = -cur[o + 2];
        } else {
            for (let i = 0; i < POSE_STRIDE; i++) out[i] = cur[i];
        }
        for (let j = 0; j < JOINT_COUNT; j++) {
            const n = this.joints[j];
            if (n == null) continue;
            n.setRotation(Vec3(out[j * 3], out[j * 3 + 1], out[j * 3 + 2]));
        }
        const hips = this.joints[0];
        if (hips != null) {
            const o = JOINT_COUNT * 3;
            hips.setPosition(Vec3(HIPS_REST_X + out[o], HIPS_REST_Y + out[o + 1], HIPS_REST_Z + out[o + 2]));
        }
    }

    // ---- the shadow, the spray, the bursts --------------------------------------------

    private drawShadow(r: Rider, p: DrawnPose): void {
        const sh = this.shadow;
        if (sh == null) return;
        const h = this.hit;
        if (!ground(p.ox, p.oz, h) || r.mode == MODE_TUMBLE && p.oy < h.y - 2) {
            sh.visible = false;
            return;
        }
        sh.visible = true;
        // on the snow, tilted to its normal: Y the normal, X across, Z along
        const nx = h.nx;
        const ny = h.ny;
        const nz = h.nz;
        // X = (0,0,1) x n, normalised; Z = X x n... any frame in the plane
        let xx = ny;
        let xy = -nx;
        let xz: f32 = 0;
        const xl = Mathf.sqrt(xx * xx + xy * xy);
        xx /= xl;
        xy /= xl;
        const zx = xy * nz - xz * ny;
        const zy = xz * nx - xx * nz;
        const zz = xx * ny - xy * nx;
        sh.local = Mat4(Vec4(xx, xy, xz, 0), Vec4(nx, ny, nz, 0), Vec4(zx, zy, zz, 0), Vec4(p.ox, h.y + 0.04, p.oz, 1));
        const lift = this.lift;
        if (lift != null) {
            let above = p.oy - h.y;
            if (above < 0) above = 0;
            lift.setTime(clampf(above / SHADOW_LIFT_HEIGHT, 0, 1));
        }
    }

    private drawSpray(r: Rider, p: DrawnPose): void {
        const sp = this.spray;
        if (sp == null) return;
        // at the board's tail, on the snow
        const fx = -Mathf.sin(r.heading);
        const fz = -Mathf.cos(r.heading);
        sp.setPosition(Vec3(p.ox - fx * 0.6, p.oy + 0.08, p.oz - fz * 0.6));
        const on = r.mode == MODE_GROUND && r.V > 5 && (r.carve > 0.25 || r.skid > 0.15);
        const e = sp as CPUParticles3D;
        if (e.emitting != on) e.emitting = on;
    }

    // The events since the last frame: a landing's burst, a perfect's sparkle.
    private events(): void {
        const ev = game.events;
        let c = this.cursor;
        if (ev.written - c > 256) c = ev.written - 256;
        for (; c < ev.written; c++) {
            const i = c % 256;
            const k = ev.kinds[i];
            if (k == EV_LAND || k == EV_CRASH) this.restart(this.burst);
            else if (k == EV_PERFECT) this.restart(this.sparkle);
        }
        this.cursor = c;
    }

    private restart(n: SceneNode?): void {
        if (n == null) return;
        const body = this.body;
        if (body != null) {
            const g = body.local.wAxis;
            n.setPosition(Vec3(g.x, g.y + 0.1, g.z));
        }
        (n as CPUParticles3D).restart();
    }
}

function grabToPose(g: i32): i32 {
    if (g == GRAB_INDY) return POSE_INDY;
    if (g == GRAB_MELON) return POSE_MELON;
    if (g == GRAB_METHOD) return POSE_METHOD;
    if (g == GRAB_MUTE) return POSE_MUTE;
    return -1;
}
