// Where a particle starts and which way it goes (docs/engine/PARTICLES.md
// "Emission"): Godot 4.4's formulas from CPUParticles3D::_particles_process,
// each a pure function over the particle's own random stream (random.as),
// drawing its numbers in Godot's order so that the simulation (sim.as)
// draws them in the order the spec fixes: the spread's two angles, then
// (after the velocity and the lifetime) the shape's. Everything is in the
// emitter's own space; sim.as takes it to the scene's when local_coords is
// off. Trigonometry from base/vecmath (software, the same bits on every
// host); sqrt is exact. Allocates nothing.

import { Vec3, cosf, powf, sinf, tanf, toRadians } from "../../base/vecmath";
import { ParticleRandom } from "./random";

const TAU: f32 = 6.28318530717958647692;

// The direction a particle leaves in: `direction` (normalised; (0, 0, 1)
// when it is zero), spread by up to `spread` degrees about it, the second
// angle flattened by `flatness` (1: in the plane of the direction and its
// binormal), Godot's construction (the binormal is Y x direction, or Z when
// the direction is along Y). Two draws. A unit vector.
export function spreadDirection(rng: ParticleRandom, direction: Vec3, spread: f32, flatness: f32): Vec3 {
    const a1 = toRadians((rng.next() * 2 - 1) * spread);
    const a2 = toRadians((rng.next() * 2 - 1) * (1 - flatness) * spread);
    const xzx = sinf(a1);
    const xzz = cosf(a1);
    const yzy = sinf(a2);
    const yzz = cosf(a2);
    const sx = xzx * yzz;
    const sy = yzy;
    const sz = xzz * yzz;
    let d = direction;
    if (d.lengthSquared() > 0) d = d.normalizeOrZero();
    else d = Vec3(0, 0, 1);
    let binormal = Vec3(0, 1, 0).cross(d);
    if (binormal.lengthSquared() < <f32>0.00000001) binormal = Vec3(0, 0, 1);
    binormal = binormal.normalizeOrZero();
    const normal = binormal.cross(d);
    return binormal * sx + normal * sy + d * sz;
}

// emission_shape sphere: Godot's point "in" the sphere of `radius` (a
// point of its surface by s and t, pulled toward the centre by x: not
// uniform in volume, Godot's). Three draws.
export function spherePoint(rng: ParticleRandom, radius: f32): Vec3 {
    const s = rng.next() * 2 - 1;
    const t = TAU * rng.next();
    const x = rng.next();
    const r = radius * Mathf.sqrt(1 - s * s);
    return Vec3(r * cosf(t), r * sinf(t), radius * s) * x;
}

// emission_shape sphere_surface: a point on the sphere's surface (uniform:
// s is uniform in z). Two draws.
export function sphereSurfacePoint(rng: ParticleRandom, radius: f32): Vec3 {
    const s = rng.next() * 2 - 1;
    const t = TAU * rng.next();
    const r = radius * Mathf.sqrt(1 - s * s);
    return Vec3(r * cosf(t), r * sinf(t), radius * s);
}

// emission_shape box: a point in the box of half-sides `extents`. Three
// draws.
export function boxPoint(rng: ParticleRandom, extents: Vec3): Vec3 {
    const x = rng.next() * 2 - 1;
    const y = rng.next() * 2 - 1;
    const z = rng.next() * 2 - 1;
    return Vec3(x * extents.x, y * extents.y, z * extents.z);
}

// emission_shape points and directed_points: which of `count` points (more
// than 0) a particle starts at, uniformly (Godot draws Math::rand() %
// count from the global generator; here the particle's stream). One draw.
export function pointIndex(rng: ParticleRandom, count: i32): i32 {
    const i = <i32>Mathf.floor(rng.next() * <f32>count);
    return i < 0 ? 0 : (i >= count ? count - 1 : i);
}

// directed_points: `v` taken into the basis Godot builds from the point's
// normal (tangent = normalise(v0 x n), bitangent = normalise(tangent x n),
// with v0 Z, or Y when the normal is nearly along Z): what was along +Z
// (the spread's axis) goes along the normal.
export function alongNormal(n: Vec3, v: Vec3): Vec3 {
    const v0 = Mathf.abs(n.z) < <f32>0.999 ? Vec3(0, 0, 1) : Vec3(0, 1, 0);
    const tangent = v0.cross(n).normalizeOrZero();
    const bitangent = tangent.cross(n).normalizeOrZero();
    return tangent * v.x + bitangent * v.y + n * v.z;
}

// `v` turned by `angle` radians about the unit `axis` (Godot's
// Vector3::rotate, Basis(axis, angle).xform: Rodrigues' formula).
function rotated(v: Vec3, axis: Vec3, angle: f32): Vec3 {
    const c = cosf(angle);
    const s = sinf(angle);
    return v * c + axis.cross(v) * s + axis * (axis.dot(v) * (1 - c));
}

// emission_shape ring (Godot 4.3's, with its cone): a point between the
// circles of `inner` and `radius` (uniform in area) about `axis` (zero:
// Z), at a height across `height` centred on the emitter; a cone angle
// below 90 narrows the ring toward its top (the top radius is radius -
// tan(90 - cone) x height, at least 0), the heights then skewed toward the
// wider end as Godot does. Three draws: the height, the angle, the radius.
export function ringPoint(rng: ParticleRandom, axisIn: Vec3, height: f32, radius: f32, inner: f32, cone: f32): Vec3 {
    const rc = radius > <f32>0.001 ? radius : <f32>0.001;
    let top = rc - tanf(toRadians(90 - cone)) * height;
    if (!(top > 0)) top = 0;
    let y = rng.next();
    const lo = rc < top ? rc : top;
    const hi = rc > top ? rc : top;
    let skew = lo / hi;
    if (!(skew > <f32>0.5)) skew = 0.5;
    y = rc < top ? powf(y, skew) : 1 - powf(y, skew);
    const angle = rng.next() * TAU;
    let rr = Mathf.sqrt(rng.next() * (rc * rc - inner * inner) + inner * inner);
    rr = rr + (rr * (top / rc) - rr) * y;
    const zero = axisIn.x == 0 && axisIn.y == 0 && axisIn.z == 0;
    const axis = zero ? Vec3(0, 0, 1) : axisIn.normalizeOrZero();
    const ax = Vec3(Mathf.abs(axis.x), Mathf.abs(axis.y), Mathf.abs(axis.z));
    let ortho = ax.x == 1 && ax.y == 0 && ax.z == 0 ? Vec3(0, 1, 0).cross(axis) : Vec3(1, 0, 0).cross(axis);
    ortho = ortho.normalizeOrZero();
    ortho = rotated(ortho, axis, angle).normalizeOrZero();
    return ortho * rr + axis * (y * height - height / 2);
}
