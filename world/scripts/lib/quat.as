// Small in-place vector and quaternion maths for the rider (docs/RIDER.md,
// section 5: the air's rotation integrated as a quaternion). f32
// throughout, every operation in a fixed order; nothing allocates once the
// objects exist.

export class V3 {
    x: f32 = 0;
    y: f32 = 0;
    z: f32 = 0;

    set(x: f32, y: f32, z: f32): V3 {
        this.x = x;
        this.y = y;
        this.z = z;
        return this;
    }

    copy(o: V3): V3 {
        this.x = o.x;
        this.y = o.y;
        this.z = o.z;
        return this;
    }

    dot(x: f32, y: f32, z: f32): f32 {
        return this.x * x + this.y * y + this.z * z;
    }

    length(): f32 {
        return Mathf.sqrt(this.x * this.x + this.y * this.y + this.z * this.z);
    }

    normalize(): V3 {
        const l = this.length();
        if (l > 1e-9) {
            this.x /= l;
            this.y /= l;
            this.z /= l;
        }
        return this;
    }

    // this = a x b
    cross(ax: f32, ay: f32, az: f32, bx: f32, by: f32, bz: f32): V3 {
        this.x = ay * bz - az * by;
        this.y = az * bx - ax * bz;
        this.z = ax * by - ay * bx;
        return this;
    }
}

export class Q {
    x: f32 = 0;
    y: f32 = 0;
    z: f32 = 0;
    w: f32 = 1;
    // the last rotate()'s result
    rx: f32 = 0;
    ry: f32 = 0;
    rz: f32 = 0;

    set(x: f32, y: f32, z: f32, w: f32): Q {
        this.x = x;
        this.y = y;
        this.z = z;
        this.w = w;
        return this;
    }

    copy(o: Q): Q {
        this.x = o.x;
        this.y = o.y;
        this.z = o.z;
        this.w = o.w;
        return this;
    }

    identity(): Q {
        return this.set(0, 0, 0, 1);
    }

    // A turn of `a` radians about the unit axis (ax, ay, az).
    setAxisAngle(ax: f32, ay: f32, az: f32, a: f32): Q {
        const h = a * 0.5;
        const s = Mathf.sin(h);
        return this.set(ax * s, ay * s, az * s, Mathf.cos(h));
    }

    normalize(): Q {
        const n = Mathf.sqrt(this.x * this.x + this.y * this.y + this.z * this.z + this.w * this.w);
        if (n > 1e-9) {
            this.x /= n;
            this.y /= n;
            this.z /= n;
            this.w /= n;
        } else {
            this.identity();
        }
        return this;
    }

    // this = this * (x, y, z, w): a turn about the body's own axes.
    mulRight(bx: f32, by: f32, bz: f32, bw: f32): Q {
        const ax = this.x;
        const ay = this.y;
        const az = this.z;
        const aw = this.w;
        this.x = aw * bx + ax * bw + ay * bz - az * by;
        this.y = aw * by - ax * bz + ay * bw + az * bx;
        this.z = aw * bz + ax * by - ay * bx + az * bw;
        this.w = aw * bw - ax * bx - ay * by - az * bz;
        return this;
    }

    // this = (x, y, z, w) * this: a turn about the world's axes.
    mulLeft(ax: f32, ay: f32, az: f32, aw: f32): Q {
        const bx = this.x;
        const by = this.y;
        const bz = this.z;
        const bw = this.w;
        this.x = aw * bx + ax * bw + ay * bz - az * by;
        this.y = aw * by - ax * bz + ay * bw + az * bx;
        this.z = aw * bz + ax * by - ay * bx + az * bw;
        this.w = aw * bw - ax * bx - ay * by - az * bz;
        return this;
    }

    // Turns by `a` radians about the body's unit axis (ax, ay, az).
    turnLocal(ax: f32, ay: f32, az: f32, a: f32): Q {
        const h = a * 0.5;
        const s = Mathf.sin(h);
        this.mulRight(ax * s, ay * s, az * s, Mathf.cos(h));
        return this.normalize();
    }

    // Turns by `a` radians about the world's unit axis (ax, ay, az).
    turnWorld(ax: f32, ay: f32, az: f32, a: f32): Q {
        const h = a * 0.5;
        const s = Mathf.sin(h);
        this.mulLeft(ax * s, ay * s, az * s, Mathf.cos(h));
        return this.normalize();
    }

    // The body's vector (vx, vy, vz) in the world, into rx, ry, rz.
    rotate(vx: f32, vy: f32, vz: f32): void {
        // t = 2 q.xyz x v; v' = v + w t + q.xyz x t
        const tx = 2 * (this.y * vz - this.z * vy);
        const ty = 2 * (this.z * vx - this.x * vz);
        const tz = 2 * (this.x * vy - this.y * vx);
        this.rx = vx + this.w * tx + (this.y * tz - this.z * ty);
        this.ry = vy + this.w * ty + (this.z * tx - this.x * tz);
        this.rz = vz + this.w * tz + (this.x * ty - this.y * tx);
    }

    // The rotation whose columns are the orthonormal right (X), up (Y) and
    // back (Z) axes.
    setBasis(xx: f32, xy: f32, xz: f32, yx: f32, yy: f32, yz: f32, zx: f32, zy: f32, zz: f32): Q {
        const tr = xx + yy + zz;
        if (tr > 0) {
            const s = Mathf.sqrt(tr + 1) * 2;
            this.w = 0.25 * s;
            this.x = (yz - zy) / s;
            this.y = (zx - xz) / s;
            this.z = (xy - yx) / s;
        } else if (xx > yy && xx > zz) {
            const s = Mathf.sqrt(1 + xx - yy - zz) * 2;
            this.w = (yz - zy) / s;
            this.x = 0.25 * s;
            this.y = (yx + xy) / s;
            this.z = (zx + xz) / s;
        } else if (yy > zz) {
            const s = Mathf.sqrt(1 + yy - xx - zz) * 2;
            this.w = (zx - xz) / s;
            this.x = (yx + xy) / s;
            this.y = 0.25 * s;
            this.z = (zy + yz) / s;
        } else {
            const s = Mathf.sqrt(1 + zz - xx - yy) * 2;
            this.w = (xy - yx) / s;
            this.x = (zx + xz) / s;
            this.y = (zy + yz) / s;
            this.z = 0.25 * s;
        }
        return this.normalize();
    }

    // The body upright on the unit normal (nx, ny, nz), its nose (-Z)
    // towards the flat yaw `yaw` (0 faces -Z, positive turns left).
    setOnGround(yaw: f32, nx: f32, ny: f32, nz: f32): Q {
        // forward, flat, projected on the plane
        let fx = -Mathf.sin(yaw);
        let fy: f32 = 0;
        let fz = -Mathf.cos(yaw);
        const d = fx * nx + fy * ny + fz * nz;
        fx -= d * nx;
        fy -= d * ny;
        fz -= d * nz;
        const fl = Mathf.sqrt(fx * fx + fy * fy + fz * fz);
        if (fl < 1e-6) return this.setAxisAngle(0, 1, 0, yaw);
        fx /= fl;
        fy /= fl;
        fz /= fl;
        // Z = -forward; X = Y x Z
        const zx = -fx;
        const zy = -fy;
        const zz = -fz;
        const xx = ny * zz - nz * zy;
        const xy = nz * zx - nx * zz;
        const xz = nx * zy - ny * zx;
        return this.setBasis(xx, xy, xz, nx, ny, nz, zx, zy, zz);
    }
}

// The angle (radians, 0..pi) between two unit vectors.
export function angleBetween(ax: f32, ay: f32, az: f32, bx: f32, by: f32, bz: f32): f32 {
    let d = ax * bx + ay * by + az * bz;
    if (d > 1) d = 1;
    if (d < -1) d = -1;
    return Mathf.acos(d);
}
