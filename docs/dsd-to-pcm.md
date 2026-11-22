# DSD to PCM

How `audio/Decode` plays DSD, in a DSF file or a WavPack file: the filters that turn its 1-bit DSD into PCM, the rate they come out at, and the level. Both containers go through the same filters, so the same DSD decodes to the same samples in either. The measurements below chose them. **Every choice here is open to change.** A change edits `scripts/dsd/design-filters.py` or `VibeDSDToPCM.c`, measures again, and updates this doc.

## What plays

- **DSF files (`.dsf`)**, in Sony's DSF container: DSD64, DSD128, DSD256, and DSD512, in the 44.1 kHz family (2.8224 MHz and its multiples) and the 48 kHz family (3.072 MHz and its multiples). Mono, stereo, and the five multichannel types the fmt chunk names, up to 5.1. Both bit orders.
- **Refused:** DSDIFF (`.dff`), which can hold DST compression, and a DSF whose header fails `VibeDSF.c`'s checks. No decoder takes them, so the open fails.
- **DSD in WavPack (`.wv`)**: the same rates and families, mono to 5.1. libwavpack unpacks the DSD bytes, and these filters convert them, as they do a DSF's. "DSD in WavPack", below, has the details.
- **Not done:** DSD over PCM (DoP) and native DSD output. The section at the end says what they would need.

## The code

The container and the conversion are apart, so a second read path can reuse the first.

| File | Owns |
| --- | --- |
| `VibeDSF.c` | The header, read as hostile, and each channel's raw DSD bytes through the caller's reads: whole groups of blocks in one read, each channel's bytes as the file stores them, with silence in the file's bit order outside the samples. |
| `VibeDSDToPCM.c` | The two filter stages, with their history for each channel, a reset, and the delay. Its tables take the file's bit order. |
| `VibeDSDFilterTaps.h` | The taps, which `scripts/dsd/design-filters.py` writes. |
| `audio/AudioTypes/VibeDSD.h` | The DSD rates and their multiples, and the idle pattern, which an app shares. |
| `AudioFileHandle+DSD.m` | The handle's open of a DSF, and for either container the facts, reads, and seeks. |
| `AudioFileHandle+WavPack.m` | A WavPack DSD file's open, and its bytes from libwavpack. |

## The filters

**Stage 1** turns DSD into PCM at 352.8 kHz, or 384 kHz in the 48 kHz family. It is an equiripple FIR of 96 taps at DSD64, and 96 times the multiple above it, with one tap for each DSD bit. Its passband ends at 40 kHz, and its stopband starts at 264.6 kHz, which is where the decimation folds frequencies onto the 0 to 88.2 kHz band that stage 2 keeps. It runs a byte at a time, in the file's bit order: each of its 12 tables, one for each byte of its window, holds the sum of eight ±taps for all 256 byte values. So one output costs 12 table reads and adds at DSD64, and 12 times the multiple above it.

**Stage 2** halves that rate. It is an equiripple FIR of 97 taps, flat to 40 kHz, and stopped from 88.2 kHz. The odd length puts its center on a sample, so the whole chain's delay is 26 output frames, a whole number, and the handle hides it.

**The output rate is 176.4 kHz for every 44.1 kHz family rate, and 192 kHz for the 48 kHz family.** DSD128 and up decimate further in stage 1, so they come out at the same rate as DSD64.

## The measurements

These come from a harness that compiles the shipped `VibeDSDToPCM.c`. It feeds the converter the output of a fifth-order delta-sigma modulator, whose noise transfer function has five zeros at DC and Butterworth poles, with its out-of-band gain held to 1.5. That is the same modulator `Tests/Support/DSFFixtures.h` uses. It is more modest than a mastering modulator, so its in-band noise floor, about -120 dB, sits above a real SACD's, but its ultrasonic noise is just as loud: the whole bitstream's power, 0 dB, lies above 88 kHz.

**Two first stages were compared**: dsd2pcm's, and the equiripple design above. dsd2pcm is Sebastian Gesemann's converter, under a two-clause BSD license (read in full from the copy MPD carries, `src/pcm/Dsd2Pcm.cxx`). It is a 96-tap FIR at DSD64, run a byte at a time through tables, decimating by 8 to 352.8 kHz. Both took the same stage 2 for 176.4 kHz output, and both were also measured alone at 352.8 kHz.

| Measure | dsd2pcm's stage 1 | This stage 1 |
| --- | --- | --- |
| Passband ripple, 0 to 20 kHz | 0.001 dB | under 0.0001 dB |
| Passband ripple, 0 to 40 kHz | 0.016 dB | 0.00006 dB |
| Response at 88.2 kHz | -0.68 dB | 0 dB (stage 2 stops it) |
| Rejection from 264.6 kHz up | 81 dB | 148 dB |
| Shaped noise aliased into 0 to 20 kHz, at 176.4 kHz | -170 dB | -161 dB |
| Shaped noise aliased into 0 to 88.2 kHz, at 176.4 kHz | -164 dB | -158 dB |
| Designs for DSD128 and up | none: it is DSD64's filter | one for each multiple, by the same script |
| Taps at DSD64 | 96 | 96 |

The aliasing rows integrate the modulator's measured noise spectrum through each cascade's response. Both lie 38 dB or more below the modulator's own in-band floor. Float sums limit either to about -150 dB anyway. So neither stage 1 adds audible noise. dsd2pcm's response has deep nulls at the folds, which is why its aliasing measures lower although its worst-case rejection is weaker.

**The output's ultrasonic noise** is what stage 2 and the output rate decide. With the modulator's silence, in dB of full scale:

| Band | 176.4 kHz, both stages | 352.8 kHz, stage 1 alone (either) |
| --- | --- | --- |
| 20 Hz to 20 kHz | -120.2 | -120.2 |
| 20 to 40 kHz | -87.2 | -87.2 |
| 40 to 88.2 kHz | -65.8 | -51.3 |
| 88.2 to 176.4 kHz | none | -38.5 to -39.4 |

At 352.8 kHz, either first stage alone passes the shaped noise above 88 kHz at -39 dB, close to its full level. Removing it needs a second filter anyway, and then the band above 88 kHz holds nothing, so a 352.8 kHz output would carry half empty samples.

**CPU**, for 60 s of stereo, the whole file read through the converter on one core of an M-series Mac under a load of about 15. `vibe-libs.yml` builds `VibeDSDToPCM.c` and `VibeDSF.c` at `-O3` in every configuration, as the dr_ decoders are, so a Debug build converts as fast as a Release one:

| Build | DSD64 | DSD128 | DSD256 | DSD512 |
| --- | --- | --- | --- | --- |
| `-O3`, as shipped in every configuration | 0.41 s (148× real time) | 0.48 s (124×) | 0.67 s (89×) | 1.03 s (58×) |
| `-Os`, an app's Release default, for comparison | 0.38 s (157×) | 0.72 s (84×) | 1.49 s (40×) | 3.11 s (19×) |
| `-O0`, an app's Debug default, for comparison | 2.4 s (25×) | 3.1 s (20×) | 4.2 s (14×) | 6.5 s (9×) |

dsd2pcm's first stage costs the same, within 2%. Both stages read a linear buffer with the filters' history in front, and sum in four lanes in a fixed order. Stage 2 folds its symmetric taps, so it multiplies half as often. The tables take the file's bit order, so a file stored least significant bit first needs no pass to reverse its bytes. A read takes as many groups of blocks as fit its buffer in one read of the file. Against the first version, one ring buffer and one serial sum, this is 1.1 times as fast at DSD64 and twice as fast at DSD512, at `-O3`. The new order of the sums moves the output by at most 1.8 × 10⁻⁷, -135 dB, which is float rounding.

**The level.** A 1 kHz sine at 50% modulation, which is 0 dB SACD, reads -6.02 dBFS in every configuration measured. A tone's phase matches the DSD within a microsecond.

## The choices

1. **This stage 1, not dsd2pcm's.** The two are equal where it matters: neither adds audible noise, and they cost the same. This one is flat across the whole band stage 2 keeps, and it has a design for every DSD rate from the same script, where dsd2pcm has only DSD64's. Nothing of dsd2pcm is vendored, so it adds no notice.
2. **176.4 kHz output (192 kHz in the 48 kHz family), whatever the DSD rate, in a DSF or a WavPack file.** It keeps everything to 40 kHz and holds back the shaped noise above 88 kHz, which 352.8 kHz would pass or carry as empty samples. It costs the rest of the chain half the samples: the player, its effects, analysis, and the waveform. More devices play it.
3. **No gain.** 0 dB SACD stays at -6 dBFS. A SACD's peaks may pass 0 dB SACD, so +6 dB would put them over full scale, and a bit-perfect integer output would clip them. A player that levels tracks makes up the 6 dB anyway. An app that wants the gain gives its item a `dsdFileGain`, which the player uses when the file turns out to be DSD (`audio/Player/AGENTS.md`, Gain per file). At +3 dB, a peak at the SACD limit, +3.1 dB SACD, lands 0.1 dB over full scale, so only a disc mastered to that limit barely clips. At +6 dB, any peak above 0 dB SACD passes full scale.
4. **r8brain is not used.** Stage 2 is a fixed 2:1 FIR of 97 taps that costs less than stage 1. r8brain's resampler would add a library to the piece and change nothing measured here.

## Seeks and the length

- **The length** is the sample count over 16 times the multiple: one output frame for each 16 DSD samples at DSD64. The sample count trims the last block's padding. A file cut short keeps the samples its data holds.
- **A seek is sample-accurate.** It clears the filters' history and feeds from 27 frames before the target, which covers both filters' span, then drops the first 53 outputs. So a seek's output equals a read's from the start, sample for sample, and a seek never clicks. `testASeekLandsOnTheSampleAReadFromTheStartGives` checks it at DSD64 and DSD512.
- **The ends** read as DSD silence, including the unused bits of the last byte. When a queued track starts at frame zero and has the same DSD rate and channel order, the player supplies the filter with the adjacent track's bits on both sides of the join. It waits for a successor while enough decoded audio remains to play. A seek clears the borrowed bits. Each file keeps its whole PCM frame count.

## DSD in WavPack

**libwavpack hands out the DSD bytes, and these filters convert them** (`AudioFileHandle+WavPack.m`). Before, libwavpack's own decimator turned them into 24-bit PCM at an eighth of the DSD rate: DSD64 at 352.8 kHz, DSD128 at 705.6 kHz, and DSD256 and up refused, past the handle's 768 kHz. That passed the shaped noise above 88 kHz at about -39 dB, and a DSD64 `.wv` played differently from the same DSD in a `.dsf`.

- **The open asks for native DSD** (`OPEN_DSD_NATIVE`). Then libwavpack states 8 bits in 1 byte, its rate is a byte's, an eighth of the DSD rate (`WavpackGetSampleRate`), and its count is the bytes a channel. `WavpackGetNativeSampleRate` answers the DSD rate, which `VibeDSDRateMultiple` must name, or the open refuses the file.
- **Its bytes**, read in libwavpack 5.9.0's `unpack_dsd.c`: each unpacked 32-bit sample holds one byte, 0 to 255, interleaved by channel, as its PCM is. The first DSD sample is the byte's most significant bit, whatever the source's order: `common_utils.c` says so, and the decoders shift each bit in from the bottom. So the converter takes them most significant bit first. A damaged block unpacks as `0x55` in every byte, which these filters reject as a tone at half the DSD rate, so it plays as silence.
- **The facts are a DSF's**: float PCM at 176.4 kHz, or 192 kHz in the 48 kHz family, the length in output frames, one for each 16 DSD samples at DSD64, and `dsdSampleRate` set. Up to 6 channels, as a DSF holds. A layout follows from the channel mask, as a PCM WavPack file's does.
- **DSD256 and DSD512 play**, since the output rate no longer depends on the DSD rate.
- **A seek primes the converter as a DSF's does**: libwavpack seeks to the lead's first byte, exactly, since a DSD block decodes from its start. So a seek equals a read from the start, sample for sample. An interrupted read leaves libwavpack's context stale, and the next seek opens a fresh one, as for PCM.
- **A file cut short** opens on its stated length, and reads up to its last whole block, with no error. The bytes past the cut read as silence, so only the last 27 frames before it differ from the whole file's. Reads stop there until a seek.
- **DSD is told by its rates**: `WavpackGetNativeSampleRate` differs from `WavpackGetSampleRate` only when the first block carries the DSD flag, which is what libwavpack's decode follows. The source's bit order in the config (`QMODE_DSD_AUDIO`) only describes the source, and damage can clear it.
- **A DSD file that says hybrid is refused** (recommended, open to change). WavPack's encoder has no hybrid DSD ("hybrid mode not available for DSD!"), so such a file is damaged. It never looks for a `.wvc`, and `media/Tags` states no depth for it, so it never reads as lossless.
- **A source DSF whose sample count is not a multiple of 8** loses its last byte's few samples in WavPack: the encoder drops them, with a warning. A `.dsf` keeps them and reads its padding as silence. So the two have the same length, and only the last 27 frames, whose filters reach that byte, differ: by up to 0.023, -33 dBFS, for the fixture's 3 samples, in the last 0.15 ms. `testADSFsLastPartByteIsDroppedInWavPack` checks it.
- **The same DSD decodes the same**, bit for bit: the tables add a byte's taps in time order, whichever bit order they index. `AudioFileHandleWavPackTests` decodes each fixture's `.wv` and the `.dsf` it was packed from, and requires equal samples, in both bit orders, mono, 5.1, the 48 kHz family, and DSD64 to DSD512.

## What DoP would still need

- A second read path in `audio/Player`'s bit-perfect output: `VibeDSFReadChannels`' bytes, two at a time, with the DoP marker in a 24-bit sample at a sixteenth of the DSD rate (176.4 kHz for DSD64), bypassing every DSP stage, its volume included.
- The device's support, which nothing reads today: a check that it takes 24-bit integer at that rate in exclusive use, and a user setting to choose DoP over PCM.
- A handle that delivers the raw bytes instead of PCM, so the player can tell the two apart, with the same seek and the same length.
- Silence that is DoP silence at every pause, fade, and gap. A PCM fade over DoP is noise.

DoP would reuse `VibeDSF.c` unchanged. It takes the bytes as the file stores them, so DoP reverses a file stored least significant bit first, since DoP sends the first sample in the most significant bit.
