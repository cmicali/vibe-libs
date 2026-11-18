# Tests/Fuzz

Coverage-guided fuzz targets for the parsers that read a user's files. A crash here is a file that would crash an app's scan or its first look at a playlist. Each target calls what an app calls, with the same arguments, and nothing else. It is not a piece: it has no template and no test bundle.

## The targets

| Target | Source | What it reads |
| --- | --- | --- |
| `tags-flac`, `tags-mp3`, `tags-m4a`, `tags-wav`, `tags-aiff`, `tags-ogg`, `tags-opus` | `Targets/FuzzTags.mm` | `media/Tags`' factory, as `media/Metadata`'s parse calls it: the tag, the audio properties, the property map, the format, the MD5, the bit depth, and the art. Then the art loader's own read. The extension picks the parser before the content sniff, so each format is a target of its own. The bytes come through the ranged read, never the disk. |
| `cue` | `Targets/FuzzCue.m` | `media/Playlists`' text decoding and CUE parser, each FILE resolved with no disk. |
| `m3u` | `Targets/FuzzM3U.m` | the M3U readers: an app's import (`m3uItemsInData:relativeToDirectory:`), `m3uEntriesInText:`, and `entriesInM3UData:`. |
| `flac-cue` | `Targets/FuzzFLACCue.m` | a FLAC's own sheet (`cueEntriesEmbeddedInFLACAtURL:`). It takes a path, so each input is written to a temporary file first. |
| `art` | `Targets/FuzzArt.m` | `core/Graphics`' bounded decode at the thumbnail's size, the pixel size, and the dominant color. ImageIO is not instrumented, so only this repo's code guides the search. |

A throw from TagLib is not a finding. The parse catches it, as `AudioTrackMetadata.mm` does.

## Running them

- **`make fuzz`** builds every target with Homebrew's clang, then runs each for `FUZZ_SECONDS` (600 by default), one at a time, on `FUZZ_JOBS` workers (4). `FUZZ_TARGETS` picks some, such as `FUZZ_TARGETS="cue m3u"`. It needs `brew install llvm`, or `FUZZ_LLVM` set to another LLVM's `bin` directory. Apple's clang has no libFuzzer.
- **Each target's output is under `build/fuzz/`**, which git ignores: its grown corpus in `corpus/<target>/`, what crashed it in `crashes/<target>/`, and its runs' logs in `logs/<target>/`. A run keeps going after a crash, and saves each one.
- **`make fuzz-replay`** builds the same targets with Xcode's clang and a plain driver, `Targets/FuzzReplayMain.c`. It runs each over its seeds and its regressions once, and fails on any sanitizer report. CI runs it.
- **Every build is under Address Sanitizer and Undefined Behavior Sanitizer**, and stops at the first report. Leak detection is off, since macOS has none on Apple silicon.
- **To reproduce a crash**, run its target's binary on the file: `build/fuzz/libfuzzer/bin/tags-mp3 build/fuzz/crashes/tags-mp3/crash-…`. To shrink it, add `-minimize_crash=1 -runs=100000`.

## Seeds and dictionaries

- **`Seeds/<target>/`** holds small valid files of the target's format, each tagged, some with a picture or a sheet. `make-seeds.sh` makes the audio and pictures from a sine tone and a generated test pattern, with ffmpeg, metaflac, and sips, so none is anyone's recording. The text seeds are written in the script. Re-run it only to change the seeds, and commit what it writes.
- **`Dictionaries/`** lists each format's magic, chunk, frame, atom, and keyword spellings, which a mutation splices in.

## A crash, once found

1. Minimize it, find its cause, and fix it. A fix to TagLib's own files is a dated row in `third_party/taglib/CHANGES.md`, as MPL 1.1 asks.
2. Add the minimized file to `Regressions/<target>/`, named for what it broke, so `make fuzz-replay` runs it.
3. Add a test that reads it through the piece's API to the piece's own test bundle, so `make test` runs it too.
