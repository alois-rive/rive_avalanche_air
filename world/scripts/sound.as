// The Sound node's script (docs/AUDIO.md, section 1): starts the Spu
// processor once (audio/spu.as), publishes its knobs every frame from
// game_state's `game`, turns game.events into cues and the announcer's lines,
// reads the meter back into game.audio (beat, bar, speakingLine, lineSeq,
// failed). The work is in audio/sound_core.as, which the audio lab shares.
import { NodeScript } from "hedra_engine/script";
import { game } from "./game_state";
import { SoundCore } from "./audio/sound_core";
import { AudioDemo } from "./audio/audio_demo";

// true: the node plays audio_demo.as's scripted session itself, writing
// `game` as the gameplay would (for checking the sound in the real scene
// without the gameplay). Off in the game.
const DEMO: bool = false;

export class Sound extends NodeScript {
    core: SoundCore = new SoundCore();
    demo: AudioDemo = new AudioDemo();

    _ready(): void {
        this.core.start(game);
    }

    _process(delta: f32): void {
        if (DEMO && !this.demo.done) this.demo.step(game, delta);
        this.core.update(game);
    }
}
