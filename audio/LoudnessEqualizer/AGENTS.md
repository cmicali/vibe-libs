# audio/LoudnessEqualizer

Loudness equalization: a slow automatic gain that plays quiet and loud passages at a similar level, and a look-ahead peak limiter after it that keeps the boost from clipping. It is one realtime stage with a plain C API, `VibeLoudnessEqualizer.h`. It depends on `core/Common` for the realtime macros, and on Accelerate for the FFT. It reads no app's settings, strings, or types.

**It follows Windows' Loudness Equalization**, as [pw-loudness-eq](https://github.com/xoxorwr/pw-loudness-eq) documents and implements it for PipeWire. Its two DSP files, the leveler (`leq.c`) and the output limiter (`limiter.c`), were rebuilt here as one stage. Nothing else of that project came here: not its PipeWire modules, its plugin wrappers, its FFT, or its window. Despite the name, the method does not change the spectrum. It is one broadband gain.

## The host

**A host creates a stage at its output's rate and channels**, sets its switch and its release from any thread, and renders slices through it in place on the audio thread. A change of rate or channels needs a new stage. A host frees a stage only with no render inside it. `audio/Player` is the one host today, and its AGENTS.md says where it runs the stage.

**Off, it is a bit-perfect pass-through.** The render reads one flag and returns, so it touches no sample and counts no render.

**Turning it on warms it first.** The render resets the stage and plays the input as it is until the stage holds a full frame and the limiter's look-ahead, N + L frames. Then it crossfades to the leveled signal over 10 ms. Turning it off crossfades back over 10 ms, and the stage rests. The wet signal is late by N + L, so a switch skips or repeats about 12 ms. A crossfade over that is quieter than a cut. Turned back on while fading out, it fades straight back in with the state it kept.

**The latency, engaged, is N + L frames**: 576 at 44.1 and 48 kHz. `VibeLoudnessEqualizerLatencyFrames` reports it, and 0 while the stage rests. A host that reports what is heard adds it.

## The leveler

1. **Frames** of N = 2^⌈log2(fs / 100)⌉ samples, at most 4096, with 50% overlap. N is 512 at 44.1 and 48 kHz. The hop is H = N / 2.
2. **Each channel is windowed** with `w[n] = 16384 · (1 − cos(2π(n + ½) / N)) / H` and run through a real FFT. The window's scale is part of the method: the band thresholds are stated against it. vDSP's real FFT returns twice the transform, so each bin's power is a quarter of its square.
3. **Power sums into 25 bands**, across every channel. Their upper edges are 100, 200, 300, 400, 510, 630, 770, 920, 1080, 1270, 1480, 1720, 2000, 2320, 2700, 3150, 3700, 4400, 5300, 6400, 7700, 9500, 12000, 15500, and 24000 Hz. A band's last bin is `⌊f · N / fs + 1⌋`, at least one past the last band's, and never past H.
4. **Loudness** is `L = 1.72 · Σ max(E_b − T_b, 1e-32)^¼`, with thresholds T of 1000, 100, 31.6, 10, 3.16, 2, 1, 1, 0.316, 0.316, eleven 1s, 4, 10, 100, and 1000.
5. **The target gain** is `min((1300 / L)^1.6, 10)`, so at most +20 dB.
6. **Down at once, up slowly.** A lower target is taken at once. A higher one is approached by a weight per hop, `(N / 128) · (44100 / fs) · 0.1^min(r, 3) · 0.316^(min(r, 7) − min(r, 3))`, where r is the release, 2 to 7. At r = 4, the default, that is a time constant of about 4.6 s at any rate.
7. **The gain crossfades linearly** across each half-frame, from the last hop's gain to this one's. The stage plays a half-frame once the frame after it is measured, so the leveler is late by N.

A reset starts the gain at 10, as the original does. The stage resets only when it turns on, and plays the input as it is while it warms, so the first hop's cut is never heard.

## The limiter

1. **Every frame waits L frames** in a delay line: 16, 32, 64, or 128 up to 16, 32, 64 kHz and above. One gain covers every channel.
2. **A frame entering the delay above the tracked peak** (0.985 to start) starts a linear ramp down over L frames to `0.985 / peak`, which lands as that frame leaves. A steeper ramp already running is kept and lengthened.
3. **The gain recovers** only once the signal peaks at half the tracked peak or less. It rises by `e^(2.205 / fs)` per frame, about 19 dB a second, while the tracked peak falls by the same factor.
4. **A peak over 128**, which no signal reaches, drops the chunk to silence.

The ramp meets each peak exactly. A frame just before a peak may pass 0.985 by a little, but the output stays under full scale.

## Rules

**TRAP: the per-channel state and the tables are one allocation, cleared with `vDSP_vclr`, never `memset`.** Clang drops a `memset(0)` after `calloc`. The audio thread would then take the page faults on its first write.

**The render works in chunks of at most a half-frame**, so the slice size changes no sample. A one-frame slice and a 4096-frame slice give the same output, bit for bit.

**The switch and the release are atomics**, read once a chunk. Every other field is the render's alone, so the stage takes no lock.

## Tests

`Tests/audio/LoudnessEqualizer/VibeLoudnessEqualizerTests.m` holds the chain to values from pw-loudness-eq's own C code, run on the same signal: the gain at three points, and eight output samples on each side. The FFTs differ, so they agree to rounding: the worst sample differed by 1.5e-7. The tests also cover the bypass, the latency at each rate, the release, the ceiling, the dropped chunk, every slice size, and the switch both ways. `audio/Player`'s tests drive the stage through the master bus.
