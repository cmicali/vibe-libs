# third_party/dr_flac

dr_flac from [dr_libs](https://github.com/mackron/dr_libs), upstream commit `dfe83776`, dr_flac 0.13.4. It is Vibe's FLAC decoder (Vibe's `docs/audio-quality.md`). It reads the stream itself, through the reads of `audio/Decode`'s `AudioFileHandle`, and answers the file's facts. A FLAC it refuses does not play. Other authors' code: **do not restyle it.** It depends on nothing. Its template is `VibeLibsDrFlac`.

## Building

`dr_flac.c` is ours, the one implementation unit, with neither stdio nor Ogg. It keeps NEON enabled. The template builds it as dr_mp3's: `-O3` in every configuration, `-w`, and the static analyzer off. Apps include `"dr_flac/dr_flac.h"`, so the template searches `third_party/` itself.

## Fixes of our own

**`dr_flac.h` is modified** on the `vibe-flac-fixes` branch of `cmicali/dr_libs`.

Format and seek fixes cover an ID3v2 prefix, empty first residual partitions, stale seek tables, invalid frame headers, and a binary search that keeps the target bracketed. Damaged frames stay in the timeline as silence. A truncated frame still ends the stream. A seek past a truncated stream lands at its end. A fixed-block stream's frames are placed by its first frame's block size, not STREAMINFO's minimum, which damage can set to anything. The decoder supports 32-bit streams and their 33-bit stereo side channel. An unknown (0) length does not clamp seeks.

Damage handling covers undefined arithmetic in side channels and metadata, invalid residual partitions, bad Ogg CRCs, stale samples after failed frames, fixed-block frame numbering, false or missed sync codes, bit-stream position and exhaustion, and unreachable seekpoints. Decode and seek share the damaged-frame walk. They fill a gap only before a valid frame, resume a failed frame's search from its header, and distinguish truncation by exhausted input. A failed seek leaves the decoder at the first frame. Binary-search probes are bounded. Skipping and decoding both reject a negative LPC shift.

A CUESHEET block's raw data is freed after the metadata callback, which reads it, not before. A VORBIS_COMMENT block too short to hold its counts is skipped, not the stream refused.

Unknown-length streams use `drflac__find_unknown_total_pcm_frame_count` at open. It finds the end of the last valid frame by searching backward from the tail. The search window doubles after a miss. This supplies the nonzero length Vibe's `AudioPlayer` requires and permits bisection seeks. A STREAMINFO allowing no block is not searched.

Rice partition orders above 8 are accepted in decoding, skipping, and the 33-bit side channel. Only the streamable subset limits them (RFC 9639 sections 7 and 9.2.7). The seek fast path keeps its distance at 64 bits. A jump of 2^32 PCM frames or more must not wrap into the current frame.

Performance changes include CRC-16 eight bytes at a time, NEON and SSE2 f32 conversions that agree with scalar results outside the bit depth, and Vibe's NEON residual decoder. `drflac_read_pcm_frames_f32_planar` writes each channel straight to its own buffer. Separate stereo conversions keep planar reads from slowing interleaved reads. Measurements are in Vibe's `docs/audio-quality.md`.

## Updating

**The fixes live as a commit series on the `cmicali/dr_libs` fork**, based on upstream's `dfe83776`, with one change per commit. Keep `dr_flac.h` equal to its branch's tip. Change the decoder on its branch in a clone of the fork. Never change only this copy, and never use a scratch worktree for the fork. Commit and push the branch before copying the header here.

When re-vendoring from upstream, diff the copy against `dfe83776` and re-apply what upstream has not merged. Then run Vibe's `make test-audio`. Its `testDrFLACDecodesWhatTheFileHolds`, `testDrFLACSurvivesWhatDamagesFiles`, `testDrFLACSeeksFurtherThanThirtyTwoBitsOfFrames`, and `testDrFLACPlacesFramesByTheFirstFramesBlockSize` fail on upstream's copy. They check what decodes and seeks deliver. They check what seeks cost only near a garbage seekpoint. So a copy that seeks slowly again, as upstream's search could for seconds on a long file, passes them.

## License

Public domain (the Unlicense) or MIT No Attribution, at the recipient's choice. vibe-libs and Vibe use it under MIT No Attribution. Both texts are at the end of `dr_flac.h`. That license permits the fixes without condition. `THIRD-PARTY-NOTICES.md` at the repo root has the notice.
