# audio/Meter

Live band levels from inside a render, only while someone looks. It depends on `core/Common` and nothing else. Its band math is its own. **Today it holds what Vibe moved here.** None of it reads an app's settings, strings, or types. It opens and analyzes no file.

| File | Owns |
| --- | --- |
| `AudioLevelMeter.{h,m}` | the meter: the render's entry `VibeLevelMeterRender`, its ~100 ms publication cadence, the lifetime of one publisher session, `remove`, and the signal probe |
| `AudioLevelAnalyzer.{h,m}` | the preallocated FFT, window accumulation, stereo-power combination, and the mode's summary across windows. No publication or view knowledge |
| `AudioLevelPublisher.{h,m}` | the coherent snapshot that lives as long as its host, session validity, and the monotonic sequence a display reads |
| `AudioLevelPublisherInternal.h` | the narrow meter-session writer API and the publisher's state. Display clients never import it |
| `AudioLevelMath.h` | tested numeric decisions: cadence, band edges, energy scaling, normalization, and level mapping |
| `AudioLevelMeter+Debug.h` | the render suite's seam for a callback stalled between its entry and its publication. `AudioLevelMeter.m` implements it under `#if DEBUG`, beside the meter's private struct |
| `AudioLevelPublisher+Debug.{h,m}` | the publisher's counters, for a host's debug dump. The body is under `#if DEBUG` |

## The meter

**A host makes one `AudioLevelPublisher` for its life, and an `AudioLevelMeter` for a rate and a mode.** The meter is a plain C struct (`VibeLevelMeter`) the render feeds through `VibeLevelMeterRender`. `install` begins a publisher session, and `remove` ends it. `copyLevels:count:sequence:` reads the latest coherent five-level snapshot without a queue or an allocation. The sequence tells a new result from a repeated read. An ended session's snapshot is unavailable at once.

**A meter's rate and mode are fixed for its life.** A host replaces the meter when either changes. It frees the old one only once the render was seen outside it. `audio/Player` keeps a meter across demand changes and installs and removes it as levels are wanted (`audio/Player/AGENTS.md`).

**TRAP: a new session restarts the accumulator and the analyzer**, its partial window and references included (`AudioLevelMeter.m`). A host may keep a meter across sessions, so the previous track's audio would otherwise open the next session's bars. **TRAP: the render reads the session once, at the callback's entry**, and both restarts on it and publishes into it. A callback that began before a remove-and-reinstall then publishes into the ended session, and the publisher drops it. Read again at publication, it would label the old session's audio as the new one's.

**`VibeLevelMeterRender` is a checked realtime function** (`CA_REALTIME_API` under `-Werror=function-effects`). It allocates nothing, takes no locks, logs nothing, and sends no Objective-C message. The analyzer's vDSP FFT is wrapped for the checker. The publisher's writes are declared `CA_REALTIME_API` outside the checked region. A single nonblocking write claim protects the rare overlap between a retired meter's last render and its replacement. The audio thread never smooths for display.

## Analysis

**The analyzer accumulates whole windows, and the meter publishes about every 100 ms.** Every slice goes to the analyzer, which copies it into its partial window and analyzes each window in the callback that fills it. That spreads the FFT work across callbacks. Once the meter has fed `VibeLevelPublicationFrameCount` frames, it summarizes the windows so far and publishes once. Analyzer storage is allocated once for the maximum FFT size. The meter's rate selects the working window.

The analysis clock is bounded and independent of the screen. `VibeLevelFFTSizeForSampleRate` picks the power-of-two window nearest about 24 decisions per second, from 256 through 8192 frames. So a high-rate route does not multiply the decision rate, though each decision does more FFT work (8192 points at 192 kHz against 2048 at 48 kHz). Five bands span 40–100, 100–250, 250–800, 800–4000, and 4000–20000 Hz, keeping three bars for bass and low mids. Routes above 40 kHz never spend a bar on ultrasonic content. Each edge maps with `ceil` to the first bin whose center is at or above it, and is the exclusive top of one band and the bottom of the next. So no bin leaks below an edge or drives two bars. Left and right are transformed separately and their power is averaged, so opposite-polarity stereo cannot cancel to false silence. FFT energy is normalized by window size, keeping the tuning stable across rates.

**Three normalization modes, one FFT.** Relative activity normalizes each band against its own private reference per window and keeps each band's largest level. Shared spectrum converts each band's energy to energy per octave, averages it across the windows, and normalizes the five bands against one common reference. The default, balanced spectrum (`VibeAudioLevelNormalizationModeBalancedSpectrum`), starts from the shared level. Where the activity level is higher, it moves 35% of the way toward it, gated by shared support, so unsupported bands stay dark. The result keeps 9% display headroom. It reuses the same FFT and cadence. `VibeAudioLevelNormalizationModeSharedSpectrum` and `VibeAudioLevelNormalizationModeRelativeActivity` are the two unmodified endpoints. None claims to reconstruct Apple's visualizer, whose band mapping and normalization are not public.

The tunable audio half is `AudioLevelMath.h`. How a display moves its bars is the display's own, so changing visual motion cannot add FFT work. `ui/Controls`' bars move by its `EqualizerAnimationMath.h`.

## The signal probe

**It compiles only where `VIBE_VERBOSE_LOGGING` is 1.** A host arms it for a start and polls it on its own queue. `audio/Player` arms it on every voice start and holds the meter for it on hardware (`audio/Player/AGENTS.md`).

Each request observes through the first buffer with signal at or above −60 dBFS, bounded to three seconds of accumulated poll intervals or captured frames. A delayed poll can extend the wall time. It records sample time, buffer host time, frame offset, observed leading silence in milliseconds, peak, finite-sample RMS, and the nonfinite count. Before first signal, a removal completes the capture as "meter removed".

The meter owns the accumulators and lock-free result words. The capture is a C function over the render's channel pointers and stamp, with no allocation, locks, logging, or file reads. Removal and replacement complete at once with the last coherent partial capture, or report no buffers. Stale polls cannot complete a newer request. A busy read keeps any prior coherent sample data with `snapshotBusy` set.

**The clock is the timestamp's sample time, in the host's frames.** `endSignalOverlapAtTime:` marks where an outgoing fade settled. Before it, nothing is captured. Every offset is computed in whole frames. `observationStartMS` exposes the excluded prefix. `observedLeadingSilenceMS` counts only inspected silent frames. `firstSignalAfterStartMS` locates the threshold crossing relative to the start, or is −1 if none was seen. A missing start clock is reported unavailable.

These are **the samples the render hands the meter**, not DAC or acoustic measurements. A late meter can miss a file's beginning. With no threshold crossing, the observed silence is a lower bound.

## Tests

`Tests/audio/Meter/` covers the band math, the analyzer, and the publisher. They build with verbose logging on, so the probe compiles there. The iOS build compiles it off. A probe compiles the stall seam, which only tests import, on both platforms. The minimal consumer plays a tone through a meter and checks the levels it reads.

The meter's render tests stay in Vibe, since they drive it through the whole player: the stalled callback, the session restart, the signal probe, and the bars under the player's debug silent output.
