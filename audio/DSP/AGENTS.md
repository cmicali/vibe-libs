# audio/DSP

Realtime signal stages a render can host, the math they share, and the resampler a decode runs. It holds `AudioVarispeed`, the pitch fader's stage, `FadeMath.h`, the fades, and `AudioResampler`. It came from Vibe. The FX math and the band math went to `audio/FX` and `audio/Meter`, their only users. The analysis framing went to `audio/Analysis`, its only user. It depends on `third_party/r8brain` for the resampler.

## AudioVarispeed

**A pitch stage with a plain C API.** A host creates a stage, sets its pitch from its own queue, and renders slices on the audio thread through an input callback that pulls the source. It needs no type of any app. The stage owns the kernel and its tables, the ring, the position, the bypass at zero, the engage and disengage, and the replay. `audio/Player` hosts one per source segment, before its FX, at the bus rate.

**At zero pitch it is a bit-perfect pass-through**: nothing converted, delayed or copied. The bypass is what makes zero exact, since the kernel is a low-pass at a ratio of 1 too. A stage builds no kernel until the pitch first leaves zero.

**The kernel** is a Kaiser-windowed sinc with a 64-frame half-width before stretching. It reads a polyphase table with cubic interpolation across phases and sums in double. Its −6 dB point is 22 kHz at 48 kHz, the same fraction of any rate. Above a ratio of 1 it is stretched by the ratio, so its cutoff follows the output's Nyquist. `VibeVarispeedSetPitch` builds a new stretch's table on the caller's queue and publishes it by pointer. The render ramps the ratio across each slice, so a drag glides. A slice that ramps the ratio down keeps the table it last used, which is stretched for where the ramp starts. The target's table would let the start of the ramp fold back.

**TRAP: a replaced table is freed only once the render no longer uses it** (`VibeVarispeedRetire`). The host decides when no render is inside. `audio/Player` does it after the render leaves.

**The edges.** Leaving zero, the stage plays whole slices directly until it has recorded at least the widest kernel's half-width in its ring. It then starts the converter at the next source frame, its ratio ramped from 1, and pulls the source into the ring a half-width ahead. Returning to zero replays the frames it had pulled ahead before the source continues. Those are the source's own samples, so from the first frame after the return the output is the source exactly, with no frame skipped or repeated. At zero pitch settled, the ring is not written. The ring's size and the engage's history derive from the kernel's constants in `AudioVarispeed.m`, the one home of its geometry.

**The latency off zero is the kernel's half-width and one or two frames, and nothing else.** That is 64 input frames, and ceil(64 × ratio) above a ratio of 1. A host that reports what is heard adds it.

## FadeMath

**Every fade exists because a gain step at a non-zero sample clicks.** `FadeMath.h` is header-only. The declick, `kFadeDurationMilliseconds`, is 10 ms and linear, which keeps its per-sample step small at every rate. A longer fade is equal-power, so the two sides of a crossfade do not dip at the midpoint. `VibeFadeGainAtFrame` computes a gain from the frame index, never by accumulating, so a ramp lands on its target exactly. A render evaluates it per frame on the audio thread, as `audio/Player`'s voice bus does.

**The stepped fades are for a queue, not the audio thread.** `VibeFadeVolumeOverSteps` steps a log curve in `kFadeSteps` equal ratios over one declick, floored at −60 dB so the curve stays defined through silence. `audio/FX`'s send gates take it.

## The resampler

**`AudioResampler.h` wraps r8brain-free-src in a plain C API**: linear phase, its 24-bit preset, and a 1% transition band, with no quality setting. A fill pulls float32 input through a callback until it has the frames it was asked for, or the callback answers none. That ends the fill with what it produced and leaves the filter primed for more. `audio/Player`'s voice bus converts every file whose rate is not the output's with it, on its decode queue. It is not realtime.

**TRAP: it is never told the stream's end.** N frames fed come out as round(N × ratio) only once pushed through with silence, as `audio/Player`'s bus flushes a stream's end. A fill that stops at zero frames leaves the filter's length of the input inside it.

## Tests

`Tests/audio/DSP/FadeMathTests.m` checks every curve's ends, its monotonic shape, the declick's step at every rate, and constant power across a crossfade. The player's crossfade decisions, which choose among these curves, are `audio/Player`'s `AudioPrefetchRules.h`. `Tests/audio/DSP/AudioResamplerTests.m` checks the resampler's length and gain. Those tests are new here. `audio/Player`'s `ResamplerQualityTests` measures it through the voice bus at every rate pair the player meets. `Tests/audio/DSP/AudioVarispeedTests.m` drives the stage alone, with random schedules of pitch and slice size, mono, and the pitch moved from another thread. Run it under the thread sanitizer when the stage's threading changes.

The tests that render the stage through a player are `audio/Player`'s: `testPitchQuality`, which holds the stage to −145 dB of distortion and false tones, flat to 20 kHz, and the edge and position tests in its render suite. Vibe's `pitch` benchmark group measures its cost beside Apple's Varispeed unit. Vibe's `docs/audio-quality.md` has the measurements of the stage and the resampler.
