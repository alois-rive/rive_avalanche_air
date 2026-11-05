# Audio: everything synthesised by Rive's AudioProcessor

The brief: "Audio carries half of the cliché: fast music, crunchy sound
effects, and an announcer who never stops shouting", with "slightly lo-fi
samples (22 kHz) to match the era". Here every sound is **synthesised at
run time by Rive's procedural audio engine**, the `AudioProcessor` of
`rive/audio` (`rive docs animascript/threading`, "Audio processors"): a
script class whose `process()` renders blocks of samples on the audio
thread, fed by the game through shared memory. No recorded sound ships,
except as the announcer's fallback (section 7).

Why one processor rather than sound files through Hedra's
`AudioStreamPlayer3D`: the board's hiss must follow the speed and the
edge continuously (pitch and filters, which the runtime's file playback
does not have: Hedra's AUDIO.md, section 12), the music must react on the
beat, the announcer must say any trick name, and a processor renders the
same samples on every platform, so the sound is tested like the pictures
(`rive --render-audio`, section 12).

## 1. The shape of it

```
 world scripts (main lane)                       audio thread
 ─────────────────────────                       ────────────
 run.as, rider.as, tricks.as                     Spu extends AudioProcessor<SpuInputs>
        │ state each tick                          │
        ▼                                          ├─ Sequencer ── the music (section 5)
 sound.as  ── Snapshot<Knobs>  (each frame) ─────▶ ├─ Board ────── carve, wind, air, rails (section 4)
           ── Ring<Cue>       (events)     ─────▶ ├─ Voices ───── 24 SPU voices: one-shots, UI (sections 3, 8)
           ◀─ Snapshot<Meter> (each block) ──────  ├─ Announcer ── formant speech (section 6)
                                                   ├─ Mixer ────── buses, ducking, sends
                                                   └─ SPU chain ── 22 kHz grit, reverb, limiter → out
```

- **`sound.as`** (a `NodeScript` on the run scene's root, main lane) starts
  the processor once (`Audio.start(() => new Spu(), inputs)`), publishes
  the knobs every frame, pushes cues as things happen, and reads the
  meter (the music's bar and beat, whether the announcer is speaking, the
  levels) for the captions and the HUD's beat-synced pulses.
- **`Spu`** (`world/scripts/audio/spu.as` and its parts) does all the
  sound. It allocates nothing in `process`, reads the ring with
  `receiveInto` and the knobs with `latestInto` into objects made in
  `init`, and keeps its own sample clock (`startFrame`).
- If a Hedra node script cannot call `Audio.start` (to be confirmed at
  A5's first step; Hedra's world scripts are AnimaScript baked into the
  same `.riv`, and its docs show them importing `rive/net`), `sound.as`
  becomes a 2D Rive `Node` script on the `Main` artboard reading the
  same state from the view model's pins (RIVE.md, section 4): one frame
  later, no other change.

## 2. The data between the lanes

**Knobs** (a `Snapshot<Knobs>`, published every frame; the processor
smooths every value over 20 ms so a 60 Hz update never zips):

| Knob | Range | From |
|---|---|---|
| `speed` | 0 to 30 m/s | the rider |
| `carve` | 0 to 1 | the lateral demand over 1.3 g |
| `skid` | 0 to 1 | the sliding excess |
| `surface` | 0 groomed, 1 powder, 2 ice, 3 rock | under the board |
| `tuck` | 0 to 1 | |
| `air` | 0 or 1 | airborne |
| `airTime` | seconds | since take-off |
| `spinRate`, `flipRate` | degrees a second | |
| `grind` | 0 none, 1 rail, 2 box, 3 log | |
| `grindSpeed` | m/s | |
| `balance` | -1 to 1 | b (RIDER.md, section 7) |
| `progress` | 0 to 1 | s / 1,420 |
| `phase` | title, countdown, run, crash, finish, results, pause | `run.as` |
| `musicVolume`, `sfxVolume`, `voiceVolume`, `mute` | 0 to 1 | the settings |

**Cues** (a `Ring<Cue>` of 64; each `{ kind, a, b }`, played at the next
block): `ollie`, `land` (a: impact, b: quality), `perfect`, `crash`,
`bail`, `grindStart` (a: kind), `grindEnd`, `spin180` (each half-turn),
`grab`, `say` (a: line id, b: priority), `countBeep` (a: 3, 2, 1, 0 for
GO), `uiMove`, `uiSelect`, `uiBack`, `tallyTick`, `tallyEnd`,
`gradeStamp` (a: grade), `restart`, `musicState` (a: state), `confetti`,
`gateWhoosh`.

**Meter** (a `Snapshot<Meter>`, published by the processor every block):
`bar`, `beat`, `step` (the music's 16th), `speaking` (the announcer's
current line id or -1), `musicLevel`, `masterLevel`.

## 3. The SPU: the era's sound chip, as the frame is the era's GPU

The PlayStation's SPU mixed 24 voices of 4-bit ADPCM samples at up to
44.1 kHz (most games used 11 to 22 kHz) with a hardware reverb. `Spu`
reproduces what that sounds like around modern synthesis:

| Part | What | Numbers |
|---|---|---|
| Voices | a pool of 24, each one sound: an oscillator (sine, square, saw, triangle, with pulse width), noise (white, pink, metallic), a sample (the voice bank, section 7) or a short wavetable; an SPU-style envelope (linear attack, exponential decay and release, sustain level) and a pitch envelope | the 25th steals the quietest |
| Voice rate | each voice renders at its own rate, 11,025 or 22,050 Hz (the brief's 22 kHz), held and interpolated up to the output rate with a 4-point Gaussian, the SPU's own interpolation: the soft, slightly dull top end of the era | 22,050 by default; 11,025 for noise layers |
| ADPCM grit | a voice's output optionally re-quantised in blocks of 28 samples to 4 bits with a block shift, as ADPCM did | `grit` 0 to 1, 0.35 by default on drums and effects, 0 on the music's tonal parts |
| Reverb | an SPU-like room: 4 parallel combs (37, 43, 49, 53 ms), 2 all-passes (5.0 and 1.7 ms), damping, run at 22,050 Hz; sends per bus | feedback 0.78; the "Studio Medium" sound |
| Master | a soft-knee limiter, -1 dBFS ceiling | the mix at -16 LUFS integrated over a run |

Synthesis runs in `@unchecked` loops with phases in turns and the
polynomial `sinTurn` (Rive's threading guide), no `Math.sin` per sample;
the delay lines are powers of two indexed with masks (a NaN guard before
every float-to-int cast, as the guide warns).

## 4. The board

Continuous layers, always running while the rider is on the course,
their parameters from the knobs; together the board's voice.

| Layer | Synthesis | Driven by |
|---|---|---|
| Glide hiss | white noise through a band-pass (centre 900 Hz + 2,600 Hz x speed / 27, Q 0.7) and a gentle low shelf | gain by speed (silent below 1 m/s, -12 dB at 27 m/s); groomed: as is; powder: centre x 0.6 and a low-pass at 2.5 kHz (softer, "whumpf"); ice: centre x 1.4, Q 1.5, a 6 kHz shimmer |
| Edge carve | noise through a band-pass at 3.2 kHz (Q 2), amplitude-modulated by a seeded 14 to 22 Hz jitter (the edge chattering) | gain by `carve` |
| Skid scrape | brown noise plus a 3.5 to 4.5 kHz band, harsh, with grit 0.6 | gain by `skid` |
| Wind | pink noise through a low-pass sweeping 300 Hz to 1.8 kHz with speed | gain by speed² and `tuck` (+6 dB in a full tuck): the speed you hear |
| Air | the hiss and edges fade in 40 ms at take-off; the wind's low-pass opens by 40 % and a slow whoosh (band-passed noise, 0.5 Hz swell) grows with `airTime` | `air`, `airTime` |
| Spin whoosh | a short band-passed noise swell (200 ms) at each half-turn of a spin or a flip, panned by the direction | `spin180` cues |
| Rail grind | metal: white noise through 4 resonant band-passes at 523, 1,371, 2,887, 4,102 Hz (Q 30, inharmonic), and a squeal (a sine at 3.1 kHz, vibrato 6 Hz) under it | `grind` 1 or 2 (box: lower resonances, 220 to 1,300 Hz, no squeal), gain and brightness by `grindSpeed`, a wobble by `balance` |
| Log slide | wood: noise low-passed at 900 Hz, and a knock (a 180 Hz sine burst, 25 ms) every 0.4 m of travel (the bark's bumps) | `grind` 3 |

One-shots, each a voice from the pool:

| Cue | Sound |
|---|---|
| `ollie` | a snap (high-passed noise above 2 kHz, 15 ms) and a thud (a 110 Hz sine dropping to 70 Hz, 80 ms) |
| `land` | a crunch (noise low-passed at 2.5 kHz, 120 ms decay) and a thump (a 70 Hz sine, 90 ms), both scaled by the impact; sketchy: a second, smaller crunch 80 ms later |
| `perfect` | a "shing": two sines at 2,637 and 3,951 Hz, 200 ms, with the reverb's send up |
| `crash` | three thumps 90 to 160 ms apart, a snow poof (noise with a falling low-pass, 0.6 s), the board's clatter (a burst of the rail resonators, damped) |
| `bail` | one thump and a scrape |
| `grab` | a soft cloth rustle (noise band-passed at 1.2 kHz, 60 ms) |
| `ollieReady` | the crouch fully loaded: a short wooden creak (a saw gliding 170 to 240 Hz, low-passed) and a soft ting at 2,093 Hz |
| `gateWhoosh` | passing an arch: a doppler-like swoosh (band-pass sweeping 2 kHz to 400 Hz, 0.4 s) |
| `confetti` | two pops (noise bursts, 30 ms) and a crowd cheer (section 8) |

## 5. The music: "Ice Breaker (170)"

One original drum-and-bass track at 170 BPM, all synthesised, written as
patterns in a tracker-style text file (`audio/song.txt`, 16 steps a bar,
one row per instrument), compiled by `tools/make_music.py` into
`world/scripts/audio/music_data.as`. A bar lasts 1.412 s, a 16th 88.2 ms.

**Instruments** (each a voice recipe of section 3):

| Instrument | Recipe |
|---|---|
| Kick | a sine sweeping 160 to 45 Hz in 60 ms, 180 ms decay, a click of noise on top |
| Snare | noise band-passed at 1.8 kHz (160 ms) and a 190 Hz triangle (60 ms); grit 0.4 |
| Ghost snare | the snare at -14 dB, 70 ms |
| Hats | noise high-passed at 7 kHz: closed 30 ms, open 140 ms; grit 0.5 |
| Ride, crash | metallic noise (6 square waves at inharmonic ratios, the 808 way) through a high-pass, 0.6 and 1.8 s |
| The break | the kick, snares, ghosts and hats programmed as a chopped 90s break (two-step with ghost notes and swing at 54 %): a break played by the synth, not sampled |
| Reese bass | two saws detuned ±9 cents through a 24 dB low-pass (cut-off 300 to 1,400 Hz, moved by an LFO at the bar and by the section), a sub sine an octave down |
| Stabs | a minor-9th chord of saws, 120 ms, through a resonant low-pass |
| Pad | 4 detuned saws, slow attack, low-passed: the title and the results |
| Arp | a square lead, 16ths, 2-octave minor arpeggio, delay at a dotted 8th |
| Riser | noise and a saw sweeping up over 4 bars, the high-pass opening |
| Impact | a low boom (a 50 Hz sine, 1.2 s) and a reversed-noise swell before it |

**Structure and states.** The music follows the run, every change on the
next bar boundary (the next beat for the urgent ones), counted on the
processor's own sample clock so it is exact:

| State | When | What plays |
|---|---|---|
| `title` | the title | the intro: pad, sub and break with a low-pass at 500 Hz ("filtered intro", the brief); 8 bars looping |
| `start` | Start pressed | the filter opens over 2 beats into the countdown |
| `countdown` | 3, 2, 1 | the break stops; the riser over the count; the beeps on the beat |
| `warmup` | GO, sections 1 and 2 | A1: the break, the reese, the sub |
| `kickers` | section 3 | A2: + stabs and the open hats |
| `rails` | section 4 | B: + the arp, the bass line's second half |
| `split` | section 5 | A3: everything |
| `megaRiser` | s = 1,240 | the riser over 4 bars, the drums thinning |
| `megaAir` | the mega-jump's take-off | everything low-passed to 900 Hz but the sub, the riser held: the hang |
| `megaDrop` | the landing | the impact, the filter open, A3 at full |
| `finish` | the finish arch | a 1-bar stop and the impact; then `results` |
| `results` | the results | the breakdown: pad, arp, sub, a half-time break; the tally ticks on the 16ths |
| `pause` | paused | everything low-passed to 400 Hz, -10 dB |
| `crash` | a crash | the music ducked -6 dB with a low-pass at 1.2 kHz for 1.2 s |
| `restart` | a restart | a tape-stop (everything pitched down to nothing over 0.3 s), then `warmup` from its first bar after the quick start's 1.0 s |

The loop lengths are 8 or 16 bars; a run of about 90 s is about 64 bars,
so a section's music usually has time to arrive. Mixing: the music at
-20 LUFS short-term, ducked 4 dB while the announcer speaks.

## 6. The announcer: a formant voice

A shouting 90s extreme-sports announcer, synthesised: the trick names,
praise words, crash lines, the countdown and the grade.

**The voice.** A source-filter synthesiser:

- **Source**: a glottal pulse train (a Rosenberg pulse) at a fundamental
  of 180 to 280 Hz (a shout: high and pushed), with 1 % jitter, 4 %
  shimmer and aspiration noise; voiceless sounds use noise only.
- **Filter**: five formant resonators in cascade (F1 to F5, with their
  bandwidths), their targets per phoneme from a table of about 40
  ARPAbet phonemes (vowels, glides, nasals, fricatives with their noise
  bands, plosives as a closure, a burst and an aspiration), interpolated
  over 25 to 40 ms between phonemes.
- **Prosody**: each word's stressed syllable raised 25 % in pitch and
  lengthened 30 %; a phrase rises to its last stressed syllable and falls
  sharply at its end; praise words are shouted (pitch +40 %, louder,
  longer vowels: "SIIIICK!").
- **The PA**: a band-pass (250 Hz to 4 kHz), a drive (tanh, x 3), a 90 ms
  slapback at -12 dB and the reverb's send at 0.35: a man shouting through
  stadium speakers on a mountain, which also hides the synthesiser's edges.

**The lexicon** (`audio/lexicon.txt`, compiled into `voice_data.as`): each
word as phonemes with durations and stress. About 70 words cover every
line: the numbers (one-eighty to fourteen-forty, three, two, one),
FRONTSIDE, BACKSIDE, SWITCH, FRONT, BACK, FLIP, DOUBLE, INDY, MELON,
METHOD, MUTE, FIFTY, BOARDSLIDE, LOG, SLIDE, KINKED, RAINBOW, NICE, SICK,
RADICAL, INSANE, UNREAL, PERFECT, SKETCHY, OUCH, WIPEOUT, BAIL, GO, READY,
BIG, AIR, HIGH, LOW, LINE, FINAL, JUMP, NEW, RECORD, RANK, S, A, B, C,
AVALANCHE, AWESOME, YEAH, OH, and the game's title.

**What it says, and when** (`world/scripts/audio/announcer.as` on the main
lane chooses; the processor speaks):

| Event | Line | Priority |
|---|---|---|
| countdown | "THREE!", "TWO!", "ONE!", "GO!"; quick start: "READY... GO!" | 1 (always, on the beat) |
| a combo banked at 1,500 or more | its trick name (the last trick's, or "COMBO!" for 4 or more), then the praise word | 2 |
| a combo banked under 1,500 | the praise word only, if any | 3 |
| a perfect landing | "PERFECT!" before the praise | 2 |
| a crash | "OUCH!" or "WIPEOUT!" (seeded) | 1 (cuts what is being said) |
| a bail | "BAIL!" | 2 |
| the split | "HIGH LINE!" or "LOW LINE!" as the rider commits | 3 |
| the mega-jump's in-run | "FINAL JUMP!" | 2 |
| the finish | "AWESOME!" or "YEAH!" | 2 |
| the grade | "S RANK!" ... "C RANK!"; "NEW RECORD!" when it enters the table | 1 |

Rules: one line at a time; a new line waits for the current one, or
replaces it when its priority is higher; a waiting line older than 1.2 s
is dropped; never the same praise twice in a row (an alternate from the
same tier: "SICK!" / "NASTY!"). Every line is captioned (RIVE.md,
section 5).

## 7. The fallback voice bank

A formant voice can fail to be understood. **A5's gate**: 10 listeners
each hear 20 lines (trick names and praise words) once, without the
captions, and write what they heard; at least 80 % must be right. If it
fails after two rounds of tuning, the announcer switches to a voice bank:

- the lexicon's words recorded by a person (a shouted read, 22,050 Hz
  mono, trimmed, about 70 files and 1.5 MB in all), as Rive audio assets;
- decoded once at start into a shared `Blob` (`source.toBlob(
  Audio.processorSampleRate(), 1)`) and handed to the processor;
- played by the same processor: a sample voice per word, the same
  prosody (pitch shifted by resampling, words joined with 20 ms
  crossfades) and the same PA chain.

The synthesis path stays in the code (an option), the processor still does
all the playback and processing: the procedural engine is never bypassed.
No third-party voice and no text-to-speech output of an online service
ships without the person's decision on its licence.

## 8. The interface and the crowd

| Cue | Sound |
|---|---|
| `uiMove` | a square blip at 1,320 Hz, 40 ms |
| `uiSelect` | two blips, 1,760 then 2,640 Hz, 40 ms each |
| `uiBack` | a blip at 660 Hz, 60 ms, falling |
| `countBeep` | a square at 880 Hz, 120 ms; GO at 1,760 Hz, 400 ms |
| `tallyTick` | a cash register's key: a short click (noise, 8 ms) and a 2 kHz square tick, on the music's 16ths while a line counts up |
| `tallyEnd` | "ka-ching": a bell (sines at 2,093, 2,637 and 3,136 Hz with a fast decay and a slow tail) over a rattle of noise |
| `gradeStamp` | a boom (55 Hz, 0.5 s), a noise burst, the reverb's send high; the announcer's grade after it |
| the crowd | at the start and the finish: a cheer made of 12 band-passed noise voices with slow random swells and occasional whistles (sine glides 2 to 3 kHz), its level by the distance to the arch |

## 9. Determinism and the clock

Nothing in the processor reads a wall clock or an unseeded random: noise
comes from a `Pcg32` per voice, seeded by the cue that started it and the
run's seed; the music runs on the sample count since `init`. Cues are
applied at the start of the next block, so the same session gives the
same samples, block for block, at a given output rate and block size, and
`rive --render-audio` of a session is a golden (TESTS.md, case 9).

## 10. Platforms

| Platform | How it plays | Notes |
|---|---|---|
| Desktop (the native shell, the previewer) | the processor in real time on the audio thread | baked with `--aot` (or `RIVE_WAMRC` set): the interpreter would overrun its blocks |
| Web, threaded build | in an audio worklet | the page must be served cross-origin isolated (COOP and COEP headers); the first sound waits for the first click (the title's Start) |
| Web, threadless | **a processor fails as it starts** (Rive's threading guide, "Platform differences"): the degraded tier | gap E-AUDIOWEB |

**The degraded tier**, rendered from the same code: `tools/render_bank.sh`
runs the project headless in a bank mode (`--data=data/audioBank=true
--render-audio=...`) in which `sound.as` plays every sound in sequence;
the tool cuts the render into files: the music's states as loops (MP3),
the one-shots and the announcer's lines (WAV, 22 kHz), the board's layers
at three speeds. On a threadless page `sound.as` finds `failed` set on its
handle and plays those through `Audio.play` with volumes (no filters, no
pitch: the board's layers crossfaded by speed, as the kart's engine is
today). About 3 MB, loaded only by that build.

## 11. Budgets and mixing rules

| What | Budget |
|---|---|
| CPU, native, compiled | under 0.6 ms per block of 512 frames at 48 kHz (6 % of the block's 10.7 ms), measured with `--release` |
| CPU, web worklet | under 2.5 ms per 128-frame block's share of the worklet |
| Voices | 24 at once (the SPU's); the board's continuous layers and the music's instruments counted apart (they are not pooled) |
| Memory | everything made in `init`: the delay lines (about 1.2 MB of f32), the voices, the tables; 0 bytes allocated per block |
| Loudness | -16 LUFS integrated over the reference run, peaks under -1 dBFS |
| Levels | music -20 LUFS short-term; the board -22 at 20 m/s; the announcer -14; UI -20 |
| Clicks | every envelope at least 2 ms; loops and the music's notes cut at zero or under an envelope |
| Ducking | the announcer ducks the music 4 dB and the board 2 dB (attack 20 ms, release 300 ms) |

## 12. How it is checked

- **Unit renders**: `audio_test.as` runs each instrument, each board layer
  at three speeds and each cue alone through the processor offline and
  checks its length, its peak, its spectral centroid within a range, no
  NaN and no click (sample-to-sample jumps under 0.2 outside attacks).
- **The session render**: `rive . --render-audio=shots/run.wav
  --advance=96s` with the reference session's inputs, against its golden
  (the difference's energy at least 60 dB under the signal), and its
  loudness (-16 LUFS ±2).
- **The announcer's gate**: section 7.
- **Listening**: the person listens to the reference run's render at each
  audio milestone's review (PLAN.md, A5).

## 13. Files

| File | What |
|---|---|
| `world/scripts/sound.as` | the main lane: starts the processor, knobs, cues, meter, the degraded tier |
| `world/scripts/audio/spu.as` | the processor: the mixer, the SPU chain |
| `world/scripts/audio/voices.as` | the voice pool, envelopes, oscillators, noise, grit, the Gaussian interpolation |
| `world/scripts/audio/board.as` | section 4's layers |
| `world/scripts/audio/sequencer.as`, `music_data.as` | section 5 (`music_data.as` generated) |
| `world/scripts/audio/formant.as`, `voice_data.as`, `announcer.as` | section 6 (`voice_data.as` generated) |
| `world/scripts/audio/reverb.as`, `dsp.as` | the reverb, `sinTurn`, filters (state-variable and biquads), the limiter |
| `audio/song.txt`, `audio/lexicon.txt` | the music's patterns, the voice's words |
| `tools/make_music.py`, `tools/make_voice.py`, `tools/render_bank.sh` | the generators and the degraded tier |
| `world/scripts/audio/*_test.as` | the unit renders |
