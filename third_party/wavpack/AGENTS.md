# third_party/wavpack

[libwavpack](https://github.com/dbry/WavPack) 5.9.0, the release tagged `5.9.0`, `src/wavpack_version.h`'s version. It is the WavPack decoder on both platforms. It is unmodified. Other authors' code: **do not restyle it.** It depends on nothing. Its template is `VibeLibsWavpack`.

## What is vendored

Only the decoder: `include/wavpack.h`, and the ten `src/` files that decode, seek, and open through a stream reader, with their three headers. They are `common_utils.c`, `decorr_utils.c`, `entropy_utils.c`, `open_utils.c`, `read_words.c`, `unpack.c`, `unpack_dsd.c`, `unpack_floats.c`, `unpack_seek.c`, and `unpack_utils.c`. The encoder, the tag reader and editor, the legacy (before 4.0) decoder, the file-name open, the raw open, the command-line tools, and the assembly are left out. `open_filename.c`, left out, is the one file with code under another author's notice.

## Building

The template searches `include/`, so callers include `<wavpack.h>`. Only `src/`'s C files join an app's project, as libvorbis's do. They build as the dr_ decoders do: `-O3` in every configuration, `-w`, and the static analyzer off. Two defines pick the build:

- `NO_TAGS` leaves the ID3v1 and APEv2 reader out. TagLib reads a WavPack file's tags (`media/Tags`).
- `ENABLE_DSD` keeps the DSD decode. `audio/Decode` opens DSD as bytes (`OPEN_DSD_NATIVE`) and converts them with its own filters, so libwavpack's decimation to PCM (`OPEN_DSD_AS_PCM`) is built but never runs.

`ENABLE_THREADS` is off, so a decode never starts threads. Apple silicon has no assembly in the release, so the C decode is the one that runs.

**TRAP: `wavpack.h` names a struct `ChunkHeader`, as CoreServices' `AIFF.h` does.** A file that also imports Foundation renames it around the include: `#define ChunkHeader VibeWavPackChunkHeader`, then `#undef` after. `audio/Decode/AudioFileHandleInternal.h` and this piece's test do.

How `audio/Decode` uses it, and what it plays and refuses, is `audio/Decode/AGENTS.md`.

## Updating

Copy the same file set from the release's `src/` and `include/`, check that it still links (this piece's test), and run this repo's `make test`, whose `AudioFileHandleWavPackTests` and WavPack fuzz family decode every fixture through it. `Tests/audio/Decode/WavPack/make-fixtures.sh` remakes the fixtures with the release's `wavpack` tool.

## License

BSD 3-Clause, in `LICENSE.txt` (upstream's `COPYING`, renamed so a build leaves it out of an app's bundle). Copyright (c) 1998 - 2025 David Bryant. Some files name Conifer Software, the author's company, under the same license. `THIRD-PARTY-NOTICES.md` at the repo root has the full text.
