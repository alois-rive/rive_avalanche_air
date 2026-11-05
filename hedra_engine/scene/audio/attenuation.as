// Milestone 36: what a listener hears of an AudioStreamPlayer3D, Godot
// 4.4's AudioStreamPlayer3D::_update_panning and _get_attenuation_db step
// for step (docs/engine/AUDIO.md "Attenuation and panning"): the
// attenuation of the distance by the model, volume_db added and max_db the
// ceiling, max_distance's fade, the emission angle's cut (applied to the
// whole sound: Godot cuts the high frequencies, the runtime has no filter),
// and the stereo balance of Godot's speaker model (Spcap, two speakers at
// ±45° in front of the listener, tightness the project's 3D panning
// strength 0.5 x 2 x panning_strength). In f32 with the library's own
// libm, so the gains are the same bits in every host.
//
// Godot's numbers, with the defaults (unit_size 10, volume_db 0, max_db 3):
// the inverse model is volume_db at one unit_size and 6.02 dB lower each
// time the distance doubles; the inverse square model 12.04 dB lower each
// doubling; the logarithmic one -20 dB at e unit_sizes; disabled, volume_db
// everywhere. A source straight to the right of the listener plays at
// 0.16910 on the left speaker and 0.98560 on the right (tightness 1,
// Godot's default), one ahead or behind at 0.70711 on both.
//
// The numbers a player's setters clamp in Godot are clamped here as the
// gains read them (the node's fields keep the file's values, so that the
// Inspector shows what the file says): unit_size 0.1 to 100, max_db -24 to
// 6, max_distance 0 to 4096, emission_angle_degrees 0.1 to 90,
// emission_angle_filter_attenuation_db -80 to 0, panning_strength 0 to 3,
// volume_db -80 to 80. Nothing here allocates.

import { Vec3, acosf, expf, lnf, powf, DEGS_PER_RAD } from "../../base/vecmath";
import { AudioStreamPlayer3D } from "../tree/node";
import { ListenerPose, normalized } from "./listener";

// Godot's AttenuationModel numbers.
export const ATTENUATION_INVERSE: i32 = 0;
export const ATTENUATION_INVERSE_SQUARE: i32 = 1;
export const ATTENUATION_LOGARITHMIC: i32 = 2;
export const ATTENUATION_DISABLED: i32 = 3;
// Godot's project setting audio/general/3d_panning_strength, 0.5: the
// speaker model's tightness is it x 2 x panning_strength.
export const GLOBAL_PANNING_STRENGTH: f32 = 0.5;
// Godot's CMP_EPSILON, added to the distance ratio.
export const ATTENUATION_EPSILON: f32 = 0.00001;

// Godot's Math::linear_to_db and db_to_linear factors (20 / ln 10 and its
// inverse).
const DB_PER_LN: f32 = <f32>8.685889638065037;
const LN_PER_DB: f32 = <f32>0.11512925464970229;
// The floor of the outputs (state.as AUDIO_SILENT_DB, repeated here so
// that the gains do not need the playback's module).
const SILENT_DB: f32 = -80;
// sqrt(1/2): each speaker's volume when the source is ahead, behind or on
// the listener, and the centred stream's share of the gain.
const HALF_POWER: f32 = <f32>0.7071067811865476;
// The speakers' directions in the listener's space (Godot's
// speaker_directions[0] and [1]: normalize(-1, 0, -1), normalize(1, 0, -1))
// and each one's effective number of speakers (Spcap's constructor: 1 +
// 0.5 x (1 + FL . FR) = 1.5 for two speakers 90° apart).
const SPEAKER_XZ: f32 = HALF_POWER;
const SPEAKER_SHARE: f32 = 1.5;
// rangeAt's bisection: to a millimetre.
const RANGE_TOLERANCE: f32 = 0.001;

// What one player sounds like at one listener.
export class AudioGains {
    // The linear gain (Godot's multiplier: attenuation, volume_db, max_db,
    // max_distance, emission angle), and it in dB (AUDIO_SILENT_DB floor).
    gain: f32 = 0;
    db: f32 = -80;
    // Godot's speaker volumes (left and right, their squares summing to 1)
    // times gain: what the left and right forms play at.
    left: f32 = 0;
    right: f32 = 0;
    // What a stream without forms plays at, centred: gain x sqrt(1/2) (the
    // same power as the two speakers').
    centre: f32 = 0;
    // (right - left) / (right + left), -1 to 1 (0 when silent).
    pan: f32 = 0;
    // The distance to the listener, metres.
    distance: f32 = 0;
}

// Godot's Math::linear_to_db and db_to_linear, in f32.
export function linearToDb(x: f32): f32 {
    return lnf(x) * DB_PER_LN;
}

export function dbToLinear(db: f32): f32 {
    return expf(db * LN_PER_DB);
}

function clampF(x: f32, lo: f32, hi: f32): f32 {
    return x < lo ? lo : (x > hi ? hi : x);
}

// The numbers as Godot's setters hold them (see the header).
export function clampedUnitSize(p: AudioStreamPlayer3D): f32 {
    return clampF(p.unitSize, 0.1, 100);
}

export function clampedMaxDb(p: AudioStreamPlayer3D): f32 {
    return clampF(p.maxDb, -24, 6);
}

export function clampedMaxDistance(p: AudioStreamPlayer3D): f32 {
    return clampF(p.maxDistance, 0, 4096);
}

export function clampedVolumeDb(p: AudioStreamPlayer3D): f32 {
    return clampF(p.volumeDb, -80, 80);
}

export function clampedEmissionAngle(p: AudioStreamPlayer3D): f32 {
    return clampF(p.emissionAngleDegrees, 0.1, 90);
}

export function clampedEmissionAttenuationDb(p: AudioStreamPlayer3D): f32 {
    return clampF(p.emissionAngleFilterAttenuationDb, -80, 0);
}

export function clampedPanningStrength(p: AudioStreamPlayer3D): f32 {
    return clampF(p.panningStrength, 0, 3);
}

// Godot's _get_attenuation_db(distance): the model's attenuation plus
// volume_db, capped at max_db. (An unknown model attenuates nothing, as
// Godot's default case.)
export function attenuationDb(model: i32, distance: f32, unitSize: f32, volumeDb: f32, maxDb: f32): f32 {
    let att: f32 = 0;
    const r = distance / unitSize;
    if (model == ATTENUATION_INVERSE) {
        att = linearToDb(<f32>1 / (r + ATTENUATION_EPSILON));
    } else if (model == ATTENUATION_INVERSE_SQUARE) {
        att = linearToDb(<f32>1 / (r * r + ATTENUATION_EPSILON));
    } else if (model == ATTENUATION_LOGARITHMIC) {
        att = <f32>-20 * lnf(r + ATTENUATION_EPSILON);
    }
    att += volumeDb;
    if (att > maxDb) att = maxDb;
    return att;
}

// Godot's multiplier at `distance` (on the emission axis): the
// attenuation's gain, faded and cut by max_distance.
function multiplierAt(p: AudioStreamPlayer3D, distance: f32): f32 {
    let m = dbToLinear(attenuationDb(p.attenuationModel, distance, clampedUnitSize(p), clampedVolumeDb(p), clampedMaxDb(p)));
    const md = clampedMaxDistance(p);
    if (md > 0) {
        if (distance > md) return 0;
        const fade = <f32>1 - distance / md;
        m *= fade > 0 ? fade : <f32>0;
    }
    return m;
}

// A multiplier in dB, AUDIO_SILENT_DB at and below silence.
function gainDb(m: f32): f32 {
    if (!(m > 0)) return SILENT_DB;
    const db = linearToDb(m);
    return db > SILENT_DB ? db : SILENT_DB;
}

// The distance (metres) at which `p` is heard at `levelDb` (its attenuation
// and max_distance's fade together, on its emission axis), for inspect's
// and the gizmo's ranges; -1 when it never falls that low (the disabled
// model without a max_distance, or a level above max_db), 0 when it is that
// low at the source already. Closed forms of each model's attenuation,
// then, when max_distance's fade brings it there first, the fade solved by
// bisection to a millimetre. Allocates nothing.
export function rangeAt(p: AudioStreamPlayer3D, levelDb: f32): f32 {
    const maxDb = clampedMaxDb(p);
    if (levelDb > maxDb) return -1;
    const md = clampedMaxDistance(p);
    const model = p.attenuationModel;
    const known = model == ATTENUATION_INVERSE || model == ATTENUATION_INVERSE_SQUARE || model == ATTENUATION_LOGARITHMIC;
    if (!known && md <= 0) return -1;
    if (gainDb(multiplierAt(p, 0)) <= levelDb) return 0;
    // Where the model alone reaches the level (never for disabled).
    let d0: f32 = Infinity;
    if (known) {
        // (the attenuation the model must give: level - volume_db)
        const a = levelDb - clampedVolumeDb(p);
        let r: f32 = 0;
        if (model == ATTENUATION_INVERSE) {
            r = dbToLinear(-a) - ATTENUATION_EPSILON;
        } else if (model == ATTENUATION_INVERSE_SQUARE) {
            const sq = dbToLinear(-a) - ATTENUATION_EPSILON;
            r = sq > 0 ? Mathf.sqrt(sq) : <f32>0;
        } else {
            r = expf(a / <f32>-20) - ATTENUATION_EPSILON;
        }
        d0 = (r > 0 ? r : <f32>0) * clampedUnitSize(p);
    }
    if (md <= 0) return d0;
    // The fade brings it lower sooner: the smallest distance up to the
    // nearer of d0 and max_distance at which it is at or below the level.
    let hi: f32 = d0 < md ? d0 : md;
    if (gainDb(multiplierAt(p, hi)) > levelDb) return hi;
    let lo: f32 = 0;
    for (let i = 0; i < 64 && hi - lo > RANGE_TOLERANCE; i++) {
        const mid = (lo + hi) * <f32>0.5;
        if (gainDb(multiplierAt(p, mid)) <= levelDb) hi = mid;
        else lo = mid;
    }
    return hi;
}

// What `listener` hears of `p` (at its global place now), into `out`.
// Allocates nothing.
export function playerGains(p: AudioStreamPlayer3D, listener: ListenerPose, out: AudioGains): void {
    const g = p.global();
    const at = g.wAxis.xyz();
    const local = listener.local(at);
    const d = local.length();
    let m = multiplierAt(p, d);
    if (p.emissionAngleEnabled && m > 0) {
        // (Godot's: the angle between the listener-to-player direction and
        // the player's +Z, so a listener in front of the player, along its
        // -Z, hears it whole)
        const toPos = normalized(at - listener.origin);
        const z = normalized(g.zAxis.xyz());
        let c = toPos.dot(z);
        c = c > 1 ? <f32>1 : (c < -1 ? <f32>-1 : c);
        const angle = acosf(c) * DEGS_PER_RAD;
        if (angle > clampedEmissionAngle(p)) m *= dbToLinear(clampedEmissionAttenuationDb(p));
    }
    out.distance = d;
    out.gain = m;
    out.db = gainDb(m);
    speakerVolumes(normalized(local), GLOBAL_PANNING_STRENGTH * 2 * clampedPanningStrength(p), out);
    out.left *= m;
    out.right *= m;
    out.centre = m * HALF_POWER;
    const sum = out.left + out.right;
    out.pan = sum > 0 ? (out.right - out.left) / sum : <f32>0;
}

// Godot's speaker volumes of a source in the direction `dir` (the
// listener's space, normalised; zero when on the listener), for the
// tightness given, into out.left and out.right (Spcap::calculate with the
// two stereo speakers).
export function speakerVolumes(dir: Vec3, tightness: f32, out: AudioGains): void {
    // (FL = (-s, 0, -s), FR = (s, 0, -s), s = sqrt(1/2))
    const dl = -SPEAKER_XZ * dir.x - SPEAKER_XZ * dir.z;
    const dr = SPEAKER_XZ * dir.x - SPEAKER_XZ * dir.z;
    const gl = <f32>0.5 * powf(<f32>1 + dl, tightness) / SPEAKER_SHARE;
    const gr = <f32>0.5 * powf(<f32>1 + dr, tightness) / SPEAKER_SHARE;
    const sl = gl * gl;
    const sr = gr * gr;
    const sum = sl + sr;
    if (!(sum > 0)) {
        out.left = HALF_POWER;
        out.right = HALF_POWER;
        return;
    }
    out.left = Mathf.sqrt(sl / sum);
    out.right = Mathf.sqrt(sr / sum);
}
