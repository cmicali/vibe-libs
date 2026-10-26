# audio/FX

The DJ chain over Apple's audio units, run in place inside a host's render. It depends on `audio/DSP`, for the stereo buffer list and the fade steps its gates take, and on `core/Common`. It came from Vibe. None of it reads an app's settings, strings, or types.

| File | Owns |
| --- | --- |
| `AudioFX.h`, `AudioFX.m` | the chain: the hosting, the intent and its ramps, the render, and the counters. The topology and the threading are `AudioFX.h`'s preamble |
| `AudioFX+Pipeline.h` | the host's half: the connect, `markDead`, the chain, the render counters, and `VibeFXChainRender` |
| `AudioFXMath.h` | the numbers a toggle or a pad position resolves to. Header-only and tested |
| `AudioFX+Debug.h` | the fault seam: an uninitialized unit refuses its next render, as under a hosting failure. `AudioFX.m` implements it under `#if DEBUG`, beside the chain's private struct |

It has the Q low-kill high-pass with its W double-cutoff boost, and three send-returns. E is a long reverb wash. R and T are BPM-synced ping-pong delays on 1/8- and 1/16-note taps, fed through `delayTapBPM`. The traps are `TRAP:` comments in `AudioFX.m`: MatrixReverb's stale header ranges, the frames per slice a directly hosted unit defaults to, the unit that writes back into a lent input buffer, and the scratch cleared with `vDSP_vclr` rather than `memset`. Clang drops a `memset(0)` after `calloc`. The audio thread would then take the page faults on its first write.

## The host

**A host owns one `AudioFX` from its init**, so the controls and the tempo feed stay stable. It hands the chain three things: its serial queue, a scheduler on its own clock, and an `afterRenderLeaves` block that runs work once no render is inside. `audio/Player` is the one host today. Its side is in `audio/Player/AGENTS.md`.

**The segment connects through `setConnected:format:maximumFrameCount:` with the output stopped, and is in the render only while connected.** The host publishes the chain's pointer into its render after a connect and withdraws it before a disconnect or a re-host. A disconnected segment costs the render nothing. Disconnect parks the EQ and defers unit resets until the render leaves. Later intent writes wait for the next connect. A disconnect with tails ringing rests every stage at once, so the output is the input, sample for sample. The units are hosted at the first connect and kept across toggles. A connect at another rate hosts them again and re-applies the recorded intent, because an effect cannot convert between its input and output.

**Hosting the ten units runs on the host's queue at the first connect.** A rate or maximum-slice change needs new units. So does a media-services reset. Work queued behind it waits. The `AudioFX: hosting` line reports its cost.

**Nothing is reset or disposed under a render.** A hosting is one allocation the render is handed whole, so a re-host swaps it. The old hosting's disposal, a stage's rest after its tail, and the disconnect's resets all wait for `afterRenderLeaves`. A stage engaged again before its deferred rest runs is left as it is.

**An iOS media-services reset** has the host withdraw the chain and call `markDead`. Ramps are preempted, deferred rests skip the orphaned units, and retirement only disposes them. The next connect hosts fresh units, even at the same rate, and re-applies the recorded intent. **The reverb unit differs per platform**: MatrixReverb on the mac, AUReverb2 on iOS, each tuned toward the same long wash.

## The render

**The segment is a stage of the host's render, not a graph.** `VibeFXChainRender` runs in place over the host's buffers on the audio thread, under `CA_REALTIME_API`. Apple's units (AUNBandEQ, MatrixReverb or AUReverb2, AUDelay) are hosted through the AudioUnit C API. Each renders with an input callback that copies the scratch into the unit's own input buffer. Every mixer is buffer arithmetic. A gate is a gain the queue targets and the audio thread slews, full scale per 25 ms. A pan is a balance law. A sum is an add. The two delay sends' identical low-cuts are one filter over their summed returns.

**TRAP: every unit's render status is read.** The first failure ends the chain's render with its status, and nothing of that unit is mixed. The caller silences the slice. A failed return holds stale scratch that would otherwise play as the current audio.

**Idle FX cost nothing, and dormant FX are sample-exact.** A stage renders only while it has work. A send works while its gate is open or its tail (`kAudioUnitProperty_TailTime`) still rings. The low kill works while on, sweeping, or settling for 250 ms after it parked flat. Otherwise a stage is reset and skipped. A connected chain with nothing engaged is then a pass-through, and `unitRenders` does not advance. The audio thread decides no activity. It reads the stages' flags. A host's idle stop reads them too (`sendsActive`, `longestTailSeconds`), so it keeps the output until a tail rests, and no longer than the longest declared tail. A rested stage joins the render before its gate opens, so it starts from silence under the gate's fade-in.

## The intent

**The intent is one number per stage** (`lowKillCutoffHz`, `reverbSendLevel`, `delaySendLevel`), **and the on-off setters write it.** A toggle resolves to the cutoff through `VibeLowKillCutoffHz` and opens a send at its base level with the held swell. A pad writes the numbers directly, which clears the toggles' memory and swells nothing. **Clearing `lowKillEnabled` also clears `lowKillBoostActive`**, because the boost modifies that filter, and a latched W must not hold the cutoff up while the low kill reads off.

A level or cutoff written on every drag frame touches the queue only on a real change. A move of an open gate is written to its target, which the audio thread slews toward. A cutoff move within `kLowKillDirectMoveRatio` of where the filter sits is written to the unit directly. Anything larger, such as an open from silence, a close, a flick, or a toggle, preempts the ramp in flight and continues from where the gate or filter sits. A stream of positions then lands as one motion without a timer per frame.

**Every toggle is click-free, and off is colorless.** Cutoff sweeps and gate fades run on the host's queue, with generation preemption. A gate steps `audio/DSP`'s `VibeFadeVolumeOverSteps`. The low kill sweeps to the 20 Hz floor, then swaps its bands to a 0 dB parametric type, an identity biquad. A high-pass parked at the floor still lifts the sub-bass through its resonant peak. Settled, the unit is reset and skipped, and a reset flat EQ is exact from its first frame.

**The numbers are `AudioFXMath.h`**: the three-way low-kill cutoff, a pad's two axes, the ping-pong tap and lane times with their no-tempo fallback, the lane feedback, and the swell target. The pad's y is the cutoff on a log curve up to `kFXPadLowCutMaxHz`. Its x is the reverb level, and past `kFXPadDelayOnset` the 1/8-note delay on top.

## Tests

`Tests/audio/FX/AudioFXMathTests.m` covers the numbers. A probe compiles the fault seam, which only tests import, on both platforms. The minimal consumer connects the chain, plays a tone through it with nothing engaged, and checks it comes back exactly.

**The chain's render tests are `audio/Player`'s**, as `AudioFXChainTests`. They run the chain over the player's manual render pump, the frame-driven clock the player renders on, so `PlayerTests` runs them. The player's render suite also drives the chain through the whole player, its fault seam included.
