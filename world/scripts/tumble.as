// The crash's tumble (docs/RIDER.md, section 9): a scripted body, not a
// ragdoll. The rider's 0.8 of its velocity and a seeded spin from the
// impact; it bounces on the course's ground (course_api ground()), its
// spin damped by each contact, until the respawn takes over at 1.15 s.
// One flail variant of two is chosen by the same seed (the poses' FlailA
// and FlailB).
import { GroundHit, ground } from "./course_api";
import { Pcg32 } from "./lib/kinematic";
import { Q } from "./lib/quat";

const G: f32 = 9.81;
const HALF_HEIGHT: f32 = 0.3;       // the body's centre above the snow when it lies on it
const RESTITUTION: f32 = 0.3;
const FRICTION: f32 = 3.5;          // m/s^2 along the snow while touching it
const SPIN_DAMP: f32 = 2.2;         // /s on the snow

export class Tumble {
    x: f32 = 0;
    y: f32 = 0;
    z: f32 = 0;
    vx: f32 = 0;
    vy: f32 = 0;
    vz: f32 = 0;
    q: Q = new Q();
    wx: f32 = 0;    // spin, rad/s, about the world's axes
    wy: f32 = 0;
    wz: f32 = 0;
    time: f32 = 0;
    variant: i32 = 0;
    touching: bool = false;
    rng: Pcg32 = new Pcg32(1, 2);
    private hit: GroundHit = new GroundHit();

    seed(seed: u64): void {
        this.rng.seed(seed, 2);
    }

    // From the rider's board place, its velocity and orientation.
    start(x: f32, y: f32, z: f32, vx: f32, vy: f32, vz: f32, q: Q): void {
        this.x = x;
        this.y = y + 0.6;
        this.z = z;
        this.vx = vx * 0.8;
        this.vy = vy * 0.8 + 1.5;
        this.vz = vz * 0.8;
        this.q.copy(q);
        const v = Mathf.sqrt(vx * vx + vz * vz);
        // a spin from the impact: about the axis across the travel, the
        // faster the more, and a seeded twist
        const k = 0.35 * (v > 4 ? v : <f32>4);
        const fx = v > 0.1 ? vx / v : <f32>0;
        const fz = v > 0.1 ? vz / v : <f32>-1;
        this.wx = -fz * k + this.rng.nextSigned() * 2;
        this.wy = this.rng.nextSigned() * 6;
        this.wz = fx * k + this.rng.nextSigned() * 2;
        this.variant = this.rng.nextF32() < 0.5 ? 0 : 1;
        this.time = 0;
        this.touching = false;
    }

    tick(dt: f32): void {
        this.time += dt;
        this.vy -= G * dt;
        this.x += this.vx * dt;
        this.y += this.vy * dt;
        this.z += this.vz * dt;
        this.touching = false;
        const h = this.hit;
        if (ground(this.x, this.z, h)) {
            const floor = h.y + HALF_HEIGHT;
            if (this.y < floor) {
                this.y = floor;
                this.touching = true;
                const vn = this.vx * h.nx + this.vy * h.ny + this.vz * h.nz;
                if (vn < 0) {
                    const j = -(1 + RESTITUTION) * vn;
                    this.vx += j * h.nx;
                    this.vy += j * h.ny;
                    this.vz += j * h.nz;
                    // a bounce kicks the spin a little
                    if (j > 2) {
                        this.wx += this.rng.nextSigned() * j * 0.5;
                        this.wz += this.rng.nextSigned() * j * 0.5;
                    }
                }
                // friction along the snow
                const vt = Mathf.sqrt(this.vx * this.vx + this.vz * this.vz);
                if (vt > 0.01) {
                    const dv = FRICTION * dt;
                    const k = vt > dv ? (vt - dv) / vt : <f32>0;
                    this.vx *= k;
                    this.vz *= k;
                }
                const damp = 1 - SPIN_DAMP * dt;
                this.wx *= damp;
                this.wy *= damp;
                this.wz *= damp;
            }
        }
        const w = Mathf.sqrt(this.wx * this.wx + this.wy * this.wy + this.wz * this.wz);
        if (w > 1e-4) this.q.turnWorld(this.wx / w, this.wy / w, this.wz / w, w * dt);
    }
}
