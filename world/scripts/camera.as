// The cameras (docs/SPEC.md, section 7), on LowRes/Lens. run.as names the
// camera wanted and hands over the drawn rider (lib/view.as); this places
// the lens:
//
// - Chase: 4.2 m behind, 1.6 m above the rider, looking 3 m ahead, a
//   critically damped spring (0.15 s) on the direction it looks from and
//   on its height (not on its place: a spring on the place trails at
//   speed, as the kart found); 66 degrees vertical, 74 in a full tuck.
//   In the air it blends to 6 m behind and 2.5 m up over 0.3 s and turns
//   towards the solved landing; on a rail to 3.5 m behind, 1.2 m up, 15
//   degrees to the rail's outside, over 0.2 s. The course's obstacles
//   between the rider and the lens pull it in front of them, and it never
//   goes under the snow.
// - Crash: holds where it was and watches the tumble until the respawn's cut.
// - Finish: 12 m past the arch, low, turned to face the rider.
// - Title (the attract): cuts between angles round the rider every 5 s.
// - Gate: in front of the rider in the start gate, for the countdown.
//
// The sky sphere (LowRes/Sky) is kept centred on the lens, as the frame
// rig asks (psx_frame.rscn), so the 1.4 km run never leaves it.
import { Camera3D, Mat4, NodeScript, SceneNode, Vec3, Vec4 } from "hedra_engine/script";
import { GroundHit, Obstacle, ground, obstacle, obstaclesNear } from "./course_api";
import { DEG, clampf, wrapAngle } from "./lib/kinematic";
import { CAM_CHASE, CAM_CRASH, CAM_FINISH, CAM_GATE, CAM_TITLE, view } from "./lib/view";

const SMOOTH: f32 = 0.15;
const FOV: f32 = 66;
const FOV_TUCK: f32 = 74;
const CLEARANCE: f32 = 0.6;   // above the snow
const MARGIN: f32 = 0.4;      // in front of an obstacle

export class ChaseCamera extends NodeScript {
    private sky: SceneNode? = null;
    private placed: bool = false;
    private yaw: f32 = 0;
    private yawV: f32 = 0;
    private cy: f32 = 0;
    private vy: f32 = 0;
    // the blends to the air's and the rail's framing (0..1)
    private air: f32 = 0;
    private rail: f32 = 0;
    private look: f32 = 0;
    // the lens's place (held by the crash camera)
    private camX: f32 = 0;
    private camY: f32 = 2;
    private camZ: f32 = 5;
    private lastMode: i32 = -1;
    private fov: f32 = FOV;
    private hit: GroundHit = new GroundHit();
    private obs: Obstacle = new Obstacle();
    private near: StaticArray<i32> = new StaticArray<i32>(16);

    override _ready(): void {
        this.sky = this.getNode("../Sky");
    }

    override _process(delta: f32): void {
        const v = view;
        const dt = delta > 0 ? (delta < 0.1 ? delta : <f32>0.1) : <f32>(1.0 / 60.0);
        const cut = v.cut || !this.placed || v.mode != this.lastMode;
        v.cut = false;
        this.lastMode = v.mode;
        let lx = v.x;
        let ly = v.y + 0.9;
        let lz = v.z;
        if (v.mode == CAM_CRASH) {
            // hold the place, watch the rider tumble
            if (cut && !this.placed) this.chase(dt, true);
            this.write(this.camX, this.camY, this.camZ, v.x, v.y + 0.3, v.z, FOV);
            return;
        }
        if (v.mode == CAM_FINISH) {
            const fx = -Mathf.sin(v.finishYaw);
            const fz = -Mathf.cos(v.finishYaw);
            // 12 m past the arch, a little to the side, low
            const cx = v.finishX + fx * 12 + fz * -3;
            const cz = v.finishZ + fz * 12 - fx * -3;
            ground(cx, cz, this.hit);
            this.write(cx, this.hit.y + 1.3, cz, lx, ly, lz, FOV);
            this.placed = false;
            return;
        }
        if (v.mode == CAM_GATE) {
            const fx = -Mathf.sin(v.travel);
            const fz = -Mathf.cos(v.travel);
            const rx = -fz;
            const rz = fx;
            const cx = v.x + fx * 4.5 + rx * 1.8;
            const cz = v.z + fz * 4.5 + rz * 1.8;
            ground(cx, cz, this.hit);
            this.write(cx, this.hit.y + 1.5, cz, lx, v.y + 1.0, lz, FOV);
            this.placed = false;
            return;
        }
        if (v.mode == CAM_TITLE) {
            this.attract(dt);
            return;
        }
        this.chase(dt, cut);
        const k = v.tuck;
        const fov = v.reducedMotion ? FOV : FOV + (FOV_TUCK - FOV) * k;
        this.fov += (fov - this.fov) * clampf(dt * 6, 0, 1);
        // in the air: the look turned towards the solved landing
        const fx = -Mathf.sin(v.travel);
        const fz = -Mathf.cos(v.travel);
        lx = v.x + fx * 3;
        lz = v.z + fz * 3;
        ly = v.y + 0.8;
        if (this.look > 0.001) {
            const w = this.look * 0.6;
            lx += (v.landX - lx) * w;
            ly += (v.landY + 0.5 - ly) * w;
            lz += (v.landZ - lz) * w;
        }
        this.write(this.camX, this.camY, this.camZ, lx, ly, lz, this.fov);
    }

    // The chase's place: behind the travel, its framing blended between the
    // snow's, the air's and the rail's.
    private chase(dt: f32, cut: bool): void {
        const v = view;
        const airT: f32 = v.inAir ? 1 : 0;
        const railT: f32 = v.grinding ? 1 : 0;
        if (cut) {
            this.air = airT;
            this.rail = railT;
            this.look = 0;
        } else {
            this.air += (airT - this.air) * clampf(dt / 0.3 * 3, 0, 1);
            this.rail += (railT - this.rail) * clampf(dt / 0.2 * 3, 0, 1);
            const lookT: f32 = v.inAir && v.airTime > 0.15 ? 1 : 0;
            this.look += (lookT - this.look) * clampf(dt * 4, 0, 1);
        }
        let back: f32 = 4.2 + (6.0 - 4.2) * this.air;
        let up: f32 = 1.6 + (2.5 - 1.6) * this.air;
        back += (3.5 - back) * this.rail;
        up += (1.2 - up) * this.rail;
        // the direction it looks from: the travel, 15 degrees to a rail's outside
        let heading = v.travel + this.rail * 15 * DEG;
        if (cut) {
            this.yaw = heading;
            this.yawV = 0;
            this.cy = v.y + up;
            this.vy = 0;
        } else {
            const omega: f32 = 2.0 / SMOOTH;
            const x = omega * dt;
            const e: f32 = 1.0 / (1.0 + x + 0.48 * x * x + 0.235 * x * x * x);
            let c = -wrapAngle(heading - this.yaw);
            let t = (this.yawV + omega * c) * dt;
            this.yawV = (this.yawV - omega * t) * e;
            this.yaw = wrapAngle(heading + (c + t) * e);
            c = this.cy - (v.y + up);
            t = (this.vy + omega * c) * dt;
            this.vy = (this.vy - omega * t) * e;
            this.cy = v.y + up + (c + t) * e;
        }
        this.placed = true;
        const cfx = -Mathf.sin(this.yaw);
        const cfz = -Mathf.cos(this.yaw);
        let reach = back;
        // an obstacle between the rider and the lens brings it in front
        const n = obstaclesNear(v.x - cfx * back * 0.5, v.z - cfz * back * 0.5, back * 0.5 + 1, this.near);
        for (let i = 0; i < n; i++) {
            obstacle(this.near[i], this.obs);
            const o = this.obs;
            if (this.cy < o.bottom || v.y > o.top) continue;
            // the obstacle's distance along the arm, and from it
            const ox = o.x - v.x;
            const oz = o.z - v.z;
            const along = -(ox * cfx + oz * cfz);
            if (along <= 0 || along > reach) continue;
            const px = ox + cfx * along;
            const pz = oz + cfz * along;
            if (px * px + pz * pz < (o.radius + 0.3) * (o.radius + 0.3)) {
                const d = along - o.radius - MARGIN;
                reach = d > 1.2 ? d : <f32>1.2;
            }
        }
        let camX = v.x - cfx * reach;
        let camZ = v.z - cfz * reach;
        let camY = this.cy;
        if (ground(camX, camZ, this.hit) && camY < this.hit.y + CLEARANCE) camY = this.hit.y + CLEARANCE;
        this.camX = camX;
        this.camY = camY;
        this.camZ = camZ;
    }

    // The title's attract: an angle round the rider every 5 s.
    private attract(dt: f32): void {
        const v = view;
        const shot = <i32>(v.phaseTime / 5) % 4;
        let off: f32 = 0;
        let dist: f32 = 5;
        let up: f32 = 1.8;
        if (shot == 1) {
            off = 140 * DEG;
            dist = 6;
            up = 1.2;
        } else if (shot == 2) {
            off = 90 * DEG;
            dist = 7;
            up = 1.0;
        } else if (shot == 3) {
            off = -30 * DEG;
            dist = 9;
            up = 5;
        }
        const yaw = v.travel + off;
        const cfx = -Mathf.sin(yaw);
        const cfz = -Mathf.cos(yaw);
        let cx = v.x - cfx * dist;
        let cz = v.z - cfz * dist;
        let cy = v.y + up;
        if (ground(cx, cz, this.hit) && cy < this.hit.y + CLEARANCE) cy = this.hit.y + CLEARANCE;
        const fx = -Mathf.sin(v.travel);
        const fz = -Mathf.cos(v.travel);
        this.write(cx, cy, cz, v.x + fx * 1.5, v.y + 0.8, v.z + fz * 1.5, FOV);
        this.placed = false;
    }

    // The lens at (cx, cy, cz) looking at (lx, ly, lz).
    private write(cx: f32, cy: f32, cz: f32, lx: f32, ly: f32, lz: f32, fov: f32): void {
        let zx = cx - lx;
        let zy = cy - ly;
        let zz = cz - lz;
        const zl = Mathf.sqrt(zx * zx + zy * zy + zz * zz);
        if (zl < 1e-4) return;
        zx /= zl;
        zy /= zl;
        zz /= zl;
        // X = up x Z, Y = Z x X
        let xx = zz;
        let xz = -zx;
        const xl = Mathf.sqrt(xx * xx + xz * xz);
        if (xl < 1e-5) return;
        xx /= xl;
        xz /= xl;
        const xy: f32 = 0;
        const yx = zy * xz - zz * xy;
        const yy = zz * xx - zx * xz;
        const yz = zx * xy - zy * xx;
        this.node.local = Mat4(Vec4(xx, xy, xz, 0), Vec4(yx, yy, yz, 0), Vec4(zx, zy, zz, 0), Vec4(cx, cy, cz, 1));
        const cam = this.node as Camera3D;
        if (cam.fov != fov) cam.fov = fov;
        const sky = this.sky;
        if (sky != null) sky.setPosition(Vec3(cx, cy, cz));
    }
}
