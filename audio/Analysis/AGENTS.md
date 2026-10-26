# audio/Analysis

Tempo and musical key from mono PCM. It depends on `audio/AudioTypes` alone, for the key. It holds `AudioBPMAnalyzer` and `AudioKeyAnalyzer`, in Objective-C++ over Accelerate, and `AnalysisFramerMath.h`, the stream framer both run behind. It came from Vibe. Nothing here logs.

## How an app uses it

**Each analyzer streams.** Make one at the file's sample rate. Feed it mono float32 blocks in file order, of any size. Call `finish` once, after the last block. Tempo answers 0 when it finds none. Key answers `VibeMusicalKeyNone`.

**Neither reads a file.** An app feeds them from a decode it already runs, so analysis costs no second read. An app attaches both to its waveform decode as observers, and the decode knows neither class (the plan's seam 17). The binding lives in the app. A window of a file, such as a CUE row, is analyzed by feeding only its frames.

**Which analyzers run is the app's choice.** Both build on both platforms.

**TRAP: a `VibeMusicalKey` of 0 is C major** (`audio/AudioTypes`). `finish` answers `VibeMusicalKeyNone` explicitly. A holder of its result must start at `VibeMusicalKeyNone` too.

## Tempo

While streaming it builds a power-spectrum spectral-flux onset envelope over 1024-sample frames at a 256 hop. At the end it runs autocorrelation and a harmonic comb over 60–200 BPM. A time-domain phase comb rescores the top candidates over a window of at most 40 seconds, to resolve 2:1 and 3:2 metrical errors. An interpolated fine pass then polishes the winner's period. Below `kMinConfidence` it returns 0. Noise, speech, and rubato land there.

Two constants settle octave errors. Both were swept on GiantSteps:

- **`kGridNormExponent`** (0.5) is the half-against-double test. The grid sum is normalized as `sum / count^exponent`. For nested grids with twice as many beats, the faster grid wins before the prior when the in-between beats average more than `2^exponent - 1` of the strong ones. That is 41% at 0.5.
- **`kTempoPriorCenterBPM`** (140, spread 80) weights every phase-comb score. For equal comb scores, T beats its half when T < 4/3 of the center. The crossover sits at about 187 BPM. It is load-bearing. A center of 120 costs 9 points of Accuracy1, a spread of 160 costs 6, and no prior costs 11. The cost is that a hip-hop or downtempo track can read 174 instead of 87.

The summation order and the double accumulators are **accuracy-bearing**. Changing them changes results.

## Key

A chromagram over FFT frames of about 0.75 s folds each bin's magnitude onto its nearest semitone's pitch class, within 55–3520 Hz. Each frame is normalized to one vote. At the end it is correlated against the 24 rotations of Sha'ath's EDM-tuned major and minor profiles. Below a correlation gate it returns `VibeMusicalKeyNone`.

Three constants carry the accuracy, all swept on GiantSteps:

- **`kHarmonicWeight`** (0.5) is worth 8 MIREX points on its own. It credits each peak to the fundamentals it could be a *harmonic of*: the note a fifth below, its 3rd harmonic, and a major third below, its 5th. Without it every note makes its own major third, and the chroma drifts major.
- **`kBassTonicWeight`** (0.15). A second chroma over the bass band (`kBassMaxHz`, 250 Hz) votes on which note the bassline treats as the root. It *supplements* the full-range chroma. Band-limiting the whole chroma measured far worse.
- **`kModeThirdWeight`** (0.45) scores the minor third against the major third. In a bare 12-bin correlation, the interval that defines the mode is one bin among twelve.

The last two exist because profile correlation finds a *scale*, not a tonal center. The relative, dominant, and subdominant keys share many scale notes. Those confusions dominated the errors. The scoring is additive over a correlation in [-1, 1]. **The confidence gate stays on the correlation alone.** It answers whether the track is tonal at all, which the other two terms cannot.

Frames are normalized to one vote and **never log-compressed**. Compressing raw magnitudes squashes loud passages harder than quiet ones.

`tuningCents` is a diagnostic, valid after `finish`. It is the mean distance of the analyzed content from equal temperament.

## Cost

Both analyzers together run at roughly 6,000x realtime in Release, about a fifth of the decode Vibe feeds them from.

At 44.1 kHz, the FFT rates are about 172 1024-point transforms per second for tempo and 2.7 32768-point transforms for key. Cheaper means fewer or smaller frames. **The tempo analyzer decimates a file at 88.2 kHz or more by a power of two first.** It runs a windowed-sinc FIR through `vDSP_desamp` and carries its history across appends, since its frame and hop are in samples. At 96 kHz that halves its cost with Accuracy1 unchanged. 44.1 and 48 kHz files take no filter and no copy.

Four measured rules hold the current floor:

- **The spectral reductions go through vDSP.** A per-sample branch does not predict, and a single accumulator serializes on float-add latency.
- **Touch only the band that votes.** The key's chroma band is a sixth of its spectrum, and the magnitude and fold passes run over it alone.
- **A scatter becomes a run.** Within the band each semitone's bins are contiguous, so the chroma fold is one reduction per semitone. The phase comb is swept **a beat at a time rather than a phase at a time**. One vDSP add per beat scores every phase at once.
- **`vDSP_DFT` is not a drop-in win over `vDSP_fft_zrip`.** It takes a third off the key's 32768-point frames and *loses* on tempo's 1024-point ones. Microbenchmarks mislead here. Measure a real decode.

**Decimating for the key analyzer would not make it cheaper**, despite its 3520 Hz ceiling. Even a short FIR runs on every sample. It would cost more than the whole analyzer, which pays for its big FFT only 2.7 times a second.

## The framing guarantee

**The block sizes an app feeds never reach a result.** So a file's tempo and key do not depend on its codec's packet size. `VibeAnalysisFrameStream`, in `AnalysisFramerMath.h`, is the one home of that guarantee. It frames a mono stream into fixed windows at a fixed hop, and calls its block once per complete frame. It splices only the frames that straddle a buffer boundary, into a carry the caller owns. Every later frame is read in place from the caller's buffer, so a block is never copied whole. The carry stays under one frame, and the owner reserves twice the frame so the splice never reallocates. It is a C++ template, so only Objective-C++ and C++ can include it.

**TRAP: `0 < hopSize <= frameSize` is a precondition of the arithmetic.** Past it, a short buffer wraps `frameCount - base` into a huge resize and an overread, and a zero hop never advances. Both analyzers satisfy it. The guard returns nothing instead, so a future caller gets no frames rather than undefined behavior.

**The framer stays here, not in `audio/DSP`.** The analyzers are its only users. In DSP it would make this piece depend on DSP, and so on r8brain, for nothing.

## Measuring

**A change meant to be exact must leave every answer identical.** Vibe's `vibe-perf` skill proves it: `VibeBenchComponents --analyze` prints each file's tempo and key through Vibe's real decode, at two commits, over the GiantSteps sets. A change meant to move the answers is scored on GiantSteps with Vibe's `scripts/analysis/validate-tempo.py` and `validate-key.py`. Neither dataset is vendored anywhere.

Tempo scores the MIREX metrics: Accuracy1 within 4%, and Accuracy2, which forgives 1/3, 1/2, 2, and 3x. Key scores the MIREX weighting: 1.0 exact, 0.5 a fifth, 0.3 relative, and 0.2 parallel. The baseline is **tempo Accuracy1 85.1% and Accuracy2 92.6%** over 652 files, and **key 61.3% weighted and 54.7% exact** over 602 files.

## Measured worse: do not retry blind

For key: narrowing the chroma band; restricting to spectral peaks, since the run-at-a-time fold cannot express a per-bin test; log-compressing the chroma at any strength; and the Krumhansl-Kessler, Temperley, and flat-diatonic profile pairs.

**Tuning correction is not worth building.** The mean offset from equal temperament is −0.2 cents median over the corpus and never exceeds ±1.8. It cannot see gross detuning. A track more than `kMaxCentsFromSemitone` (35) off has every bin rejected and shows no key.

## Tests

`Tests/audio/Analysis/` holds Vibe's tests of both analyzers and of the framer. The analyzers' tests feed synthesized click tracks and chords in arbitrary block sizes, so they pin the framing guarantee end to end. `AnalysisFramerMathTests` pins the framer's arithmetic at block sizes a decoder is unlikely to produce but a caller may, and at the edges of its precondition. They also check the tempo at 96 and 192 kHz, and that a short or empty input finds nothing. The minimal consumer finds a click track's tempo, as an app would.
