# audio/Listening

What a listener sets to suit their ears and headphones: a parametric EQ of up to 20 bands, a preamp, headphone crossfeed, and the channel tools (swap, mono, and balance). It holds the settings as values, `VibeListeningSettings.h`, the response math an editor draws from, and the realtime stage that plays them, `VibeListeningStage.h`, with a plain C API. It depends on `core/Common` for the realtime macros and `audio/DSP` for the fade math. It reads no app's settings, strings, or types.

## The settings

**`VibeEQBand` and `VibeListeningSettings` are immutable values** that compare by content. `VibeMutableListeningSettings` edits a copy, and `-copy` hands back an immutable one. They are NSSecureCoding, and `propertyList` gives plists for an app's defaults.

**Every value is held to its range where it enters**: a band's frequency to 20 Hz to 20 kHz, its gain to ±24 dB, its Q to 0.1 to 10, the manual preamp to 0 to −24 dB, the balance to ±1, and the bands to 20. A value that isn't a number takes the default. A property list that is missing a value, or holds a bad one, reads as neutral there, and never throws. A plist's band with an unknown type is dropped. A coded band with one reads as a peak. The plist names the band types and crossfeed levels by word, so the enums can grow.

**`isNeutral` means no sample would change**, so a stage can pass the signal through bit for bit. An EQ changes samples only when it is on and has a band that is not neutral, or a preamp that isn't 0 dB. A band is neutral when it is off, or a peak or shelf at 0 dB. A pass filter is never neutral.

**The preamp belongs to the EQ.** `effectivePreampDB` is 0 while the EQ is off. Automatic, it is `VibeListeningAutomaticPreampDB`: minus the curve's highest boost from 20 Hz to 20 kHz at 48 kHz, found on a log grid of 1,024 points and then by a golden-section search beside the best one, so a narrow peak between two points still counts in full. It has no floor, unlike the manual value: it cuts as far as the curve boosts.

**The graphic face** is ten peaks at 31 Hz to 16 kHz, with a Q of 1.41. `isGraphic` is true only for exactly that layout, every band on, so an editor knows which face can show the settings.

## The response

**`VibeListeningBiquad.h` holds the RBJ cookbook's biquads**, which the response math uses, so the curve an editor draws is the one that plays. A band's center is held under 0.48 of the rate. The shelves take the band's Q in the cookbook's alpha. The pass filters ignore the gain.

## The stage

**A host creates a stage at its output's rate and channels**, publishes settings from one thread at a time, and renders slices through it in place on the audio thread. A change of rate or channels needs a new stage. A host frees a stage only with no render inside it. `audio/Player` is the one host today, and its AGENTS.md says where it runs the stage.

**The order is swap, mono, preamp, EQ, crossfeed, and balance.** The preamp and the EQ act on every channel. Swap, mono, crossfeed, and balance act on the first two channels only, and do nothing on a mono stream. Mono is the mean of the two. Balance cuts the far side linearly: −0.25 plays the right at 0.75. It never boosts.

**Neutral, it is a bit-perfect pass-through.** Settings that change no sample at the stage's channels build a neutral program. Once the fade to it is over, the render reads one flag and returns, so it touches no sample and counts no render.

**Settings become a program on the queue**: each band's biquad at the stage's rate, the preamp's gain, the crossfeed's filters, and the balance's gains, with the filter state in the same allocation. The queue publishes it by pointer. A program the render never took is freed at the next publish.

**The render crossfades to a new program over 10 ms**, linearly, frame by frame, with `audio/DSP`'s `VibeFadeGainAtFrame`. It runs both programs over the fade, the old one on a copy of the input. The new program starts from the old one's filter state when they have the same number of bands, so a small edit joins two near-equal signals. A program that arrives during a fade waits until it ends. When a fade ends, the render pushes the old program onto a lock-free retired list, and the next publish frees it, so a program is freed only after the render's last read of it.

**The biquads are transposed direct form II**, with the state in double, per channel and band. A state under 1e-25 is flushed to zero after each chunk, so a decaying tail never reaches the denormal range. The render works in chunks of at most 512 frames, its scratch's length.

**Crossfeed is bs2b's** (MIT; `THIRD-PARTY-NOTICES.md`): a first-order low-pass on the crossed signal and a first-order high boost on the direct one, scaled so the sum keeps the low end level. Its levels are bs2b's three: Light is 700 Hz and 4.5 dB, Medium 700 Hz and 6 dB, and Strong 650 Hz and 9.5 dB. The feed is how far the crossed signal sits under the direct one at low frequencies.

**A clip is an output sample past ±1.0**, counted by the render while the stage is engaged. `VibeListeningStageClipping` is true while engaged with a clip in the last second of the frames the stage rendered, so a paused output holds the report. A neutral stage reports none.

**TRAP: Clang drops a memset(0) after calloc, and turns malloc and memset into calloc.** Every allocation the render writes takes a volatile write per page on the queue, so the audio thread takes no page fault.

## Tests

`Tests/audio/Listening/VibeListeningSettingsTests.m` covers each range, equality and the copies, the coding and the plist round trips, a bad plist, the graphic face, each filter's shape, and the automatic preamp. `VibeListeningStageTests.m` holds the stage to them: neutral is bit-identical, each filter type's measured response matches `VibeListeningResponseDB` within 0.1 dB from 20 Hz to 20 kHz at 44.1, 48, and 96 kHz, the automatic preamp keeps a full-scale tone at the curve's peak under full scale, a change mid-play steps no further than the settled signal does, crossfeed matches bs2b's own code and its levels, and mono, swap, balance, more than two channels, and clipping. `audio/Player`'s render tests drive the stage through the master bus.
