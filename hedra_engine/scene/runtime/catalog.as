// The run time's feature catalogue (milestone 39): the bits, names and
// roots, with no imports, so that the tools (the asset container's writer
// and Build) can name them without carrying the run
// time that features.as's hooks import. features.as re-exports every name
// here.
//
// A later milestone adds a feature by appending a bit, a name, a root and
// an installer here, its writer case (../bundle/write.as) and its row in
// docs/cli/BUILD.md section 18. compiler/tools/gen_engine_bundle.sh copies the
// roots, and its test checks that they agree with this file.

// A node has a script: the NodeScript runtime and the scripts' registry.
export const FEATURE_SCRIPTS: u32 = 1;
// A material uses an ArtboardTexture (milestones 15 and 16): live
// artboards drawn into the scene's textures.
export const FEATURE_ARTBOARDS: u32 = 2;
// A node declares a binding, or the scene names a view model (milestone
// 17): the binder and the view model's values.
export const FEATURE_BINDINGS: u32 = 4;
// Milestone 31: a node is a CollisionObject3D (Area3D, StaticBody3D), a
// CollisionShape3D or a RayCast3D: the interaction world (overlaps, rays,
// the pointer's picking) and the signals it emits.
export const FEATURE_INTERACTION: u32 = 8;

// Milestone 45: a scene declares a LinearAnimation or an Event (Rive's
// timelines, docs/plans/RIVE_MODEL.md RM2; ../anim/): its instances
// advanced and applied each frame (PHASE_ANIMATION), its events fired.
// Milestone 46: or a StateMachine (RM3; ../sm/): its machines run in the
// same phase, settled after the push (PHASE_SETTLE).
// The bit milestone 41 reserved (16), so the bits are no longer the
// names' indices: FEATURE_BITS gives each name's.
export const FEATURE_ANIMATION: u32 = <u32>1 << 16;
export const FEATURE_ANIMATION_BIT: i32 = 16;

// Milestone 35: a node is a CPUParticles3D (../particles/): its particles
// advanced every frame (after the scripts), its `finished` emitted. Bit 4
// (16), the first free one below the animation feature's 1 << 16.
export const FEATURE_PARTICLES: u32 = 16;

// Milestone 36: a node is an AudioStreamPlayer3D (../audio/): its
// playbacks advanced every frame (after the scripts and the particles),
// heard at the listener, played through the runtime's audio. Bit 5 (32).
export const FEATURE_AUDIO: u32 = 32;

// Milestone 63: a node is a NavigationRegion3D, NavigationAgent3D,
// NavigationObstacle3D or NavigationLink3D (../navigation/): the scene's
// navigation map (scripts' queries), its agents' paths and avoidance
// stepped every frame (after the scripts, the particles and the sounds,
// before the interaction world: areas see where the agents went), their
// signals emitted. Bit 6 (64).
export const FEATURE_NAVIGATION: u32 = 64;

// The names (the bundle index's, the answer's and the manifest's), and
// each one's bit, in the same order.
export const FEATURE_NAMES: StaticArray<string> = [
    "scripts", "artboards", "bindings", "interaction", "animation", "particles", "audio", "navigation",
];
export const FEATURE_BITS: StaticArray<u32> = [
    FEATURE_SCRIPTS, FEATURE_ARTBOARDS, FEATURE_BINDINGS, FEATURE_INTERACTION, FEATURE_ANIMATION, FEATURE_PARTICLES, FEATURE_AUDIO,
    FEATURE_NAVIGATION,
];

// The shared/ path of each feature's root (FEATURE_NAMES order): the
// module gen_engine_bundle.sh closes over, which exports install<Name>Feature.
export const FEATURE_ROOTS: StaticArray<string> = [
    "hedra_engine/scene/runtime/feature_scripts.as",
    "hedra_engine/scene/runtime/feature_artboards.as",
    "hedra_engine/scene/runtime/feature_bindings.as",
    "hedra_engine/scene/runtime/feature_interaction.as",
    "hedra_engine/scene/runtime/feature_animation.as",
    "hedra_engine/scene/runtime/feature_particles.as",
    "hedra_engine/scene/runtime/feature_audio.as",
    "hedra_engine/scene/runtime/feature_navigation.as",
];

// The function each feature root exports (FEATURE_NAMES order), which the
// generated engine/src/scene/runtime/features.as calls.
export const FEATURE_INSTALLERS: StaticArray<string> = [
    "installScriptsFeature", "installArtboardsFeature", "installBindingsFeature", "installInteractionFeature",
    "installAnimationFeature", "installParticlesFeature", "installAudioFeature", "installNavigationFeature",
];

// The core's roots: every export carries their closure.
export const CORE_ROOTS: StaticArray<string> = [
    "hedra_engine/scene/runtime/scene_runtime.as",
    "hedra_engine/scene/runtime/handles.as",
    "hedra_engine/scene/runtime/scene3d.as",
    "hedra_engine/scene/script.as",
];

// Milestone 27: the game program's roots (host/src/play/program.as).
// Only Play's project carries their closure, at hedra_host/ beside the
// whole library (milestone 43: compiler/tools/gen_engine_bundle.sh, its
// imports of the library made "hedra_engine/..."): the host contract's session,
// the game window and its input, which a Rive project never needs. Not a
// feature: a scene never asks for it.
export const PLAY_ROOTS: StaticArray<string> = [
    "hedra_host/play/program.as",
];

// (Milestone 41 reserved bit 16 for Rive's own model, RM2 and RM3; the
// timelines take it in milestone 45, FEATURE_ANIMATION above, and the
// state machines share it since milestone 46: a scene that declares either
// asks for it, and the .rscnb sections ANIM and STMC carry them,
// ../rscnb/format.as.)

// Every feature bit this version knows.
export const FEATURE_ALL: u32 = FEATURE_SCRIPTS | FEATURE_ARTBOARDS | FEATURE_BINDINGS | FEATURE_INTERACTION | FEATURE_ANIMATION
    | FEATURE_PARTICLES | FEATURE_AUDIO | FEATURE_NAVIGATION;

// The names of the bits of `mask`, in bit order.
export function featureNames(mask: u32): Array<string> {
    const out = new Array<string>();
    for (let i = 0; i < FEATURE_NAMES.length; i++) if ((mask & FEATURE_BITS[i]) != 0) out.push(FEATURE_NAMES[i]);
    return out;
}

// The bit of a feature's name, 0 for an unknown one.
export function featureBit(name: string): u32 {
    for (let i = 0; i < FEATURE_NAMES.length; i++) if (FEATURE_NAMES[i] == name) return FEATURE_BITS[i];
    return 0;
}

// The name of bit index `k` (0 to 31), "" for a bit this version does not
// name.
export function featureNameOfBit(k: i32): string {
    const bit = <u32>1 << <u32>k;
    for (let i = 0; i < FEATURE_BITS.length; i++) if (FEATURE_BITS[i] == bit) return FEATURE_NAMES[i];
    return "";
}
