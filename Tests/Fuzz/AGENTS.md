# Tests/Fuzz

Coverage-guided fuzz targets for the code that reads a user's files. A crash here is a file that would crash an app's scan, its play, or its first look at a playlist. Each target calls the entry point an app calls, on a file of its own, so the read takes a local file's path. It is not a piece: it has no template and no test bundle.

The pieces' XCTest fuzz suites (`AudioTrackMetadataFuzzTests`, `VibePlaylistFileFuzzTests`, and `AudioFileHandleFuzzTests`) are different. They run seeded mutations aimed at known traps, check what comes back, and run in `make test`. These targets search by coverage under sanitizers, for as long as they are given.

## The targets

| Target | Source | What it calls |
| --- | --- | --- |
| `tags-flac`, `tags-mp3`, `tags-m4a`, `tags-wav`, `tags-aiff`, `tags-ogg`, `tags-opus` | `Targets/FuzzTags.mm` | a scan's parse, `+[AudioTrackMetadata metadataWithURL:displayArtData:]`: TagLib through `media/Tags`, the fields, the CoreAudio and dr_flac fallbacks, and the thumbnail encode. An input whose last byte is odd also takes the art loader's own read. |
| `decode-flac`, `decode-mp3`, `decode-wav`, `decode-aiff`, `decode-ogg` | `Targets/FuzzDecode.m` | a play's open, `AudioFileHandle`: CoreAudio's parser, then dr_flac, dr_mp3, dr_wav, or libvorbis. It reads a few buffers, seeks to the middle, and reads again. |
| `cue` | `Targets/FuzzCue.m` | a sheet beside its audio, `cueEntriesForSheetAtURL:knownFiles:`, with each FILE resolved through the rungs. An input whose last byte is odd resolves against a walk's listing. |
| `m3u` | `Targets/FuzzM3U.m` | an M3U as an app imports it (`m3uItemsInData:relativeToDirectory:`), and as the walk reads it (`entriesForPlaylistAtURL:`). |
| `flac-cue` | `Targets/FuzzFLACCue.m` | a FLAC's own sheet, `cueEntriesEmbeddedInFLACAtURL:`. |
| `art` | `Targets/FuzzArt.m` | `core/Graphics`' bounded decode at the thumbnail, display, and archived sizes, which embedded art and covers beside the files share, then the encode, the pixel size, and the dominant color. ImageIO is not instrumented, so only this repo's code guides the search. |

The extension in each name picks the parser, as a file's does. A decode target takes its tag target's seeds. `Targets/FuzzInput.h` writes each input to a file in a folder of the process's own, which goes at exit.

## Running them

- **`make fuzz`** builds every target with Homebrew's clang, then runs each for `FUZZ_SECONDS` (600), one at a time, on `FUZZ_JOBS` workers (4). `FUZZ_TARGETS` picks some, such as `FUZZ_TARGETS="cue m3u"`. It needs `brew install llvm`, or `FUZZ_LLVM` set to another LLVM's `bin` directory. Apple's clang has no libFuzzer.
- **A target compiles what its piece's template lists**, read from `vibe-libs.yml` through `xcodegen dump`, with each source's own flags. A new file or search path needs no change here.
- **Each target's output is under `build/fuzz/`**, which git ignores: its grown corpus in `corpus/<target>/`, what crashed it in `crashes/<target>/`, and its runs' logs in `logs/<target>/`. A run keeps going after a crash, and saves each one. An allocation over 1 GB is saved too, as an `oom-…` file.
- **`make fuzz-replay`** builds the same targets with Xcode's clang and a plain driver, `Targets/FuzzReplayMain.c`. It runs each over its seeds and its regressions once, and fails on any sanitizer report, or when a target has no input. With `SINCE`, it replays only the targets a change reaches. CI runs it.
- **Every build is under Address Sanitizer and Undefined Behavior Sanitizer**, and stops at the first report. A huge allocation returns null, as it may in an app. Leak detection is off, since macOS has none on Apple silicon.
- **`scripts/fuzz/fuzz.py triage`** replays each saved artifact once with the replay build, and prints whether it still fails and its peak memory. An `oom-` file is a finding only when its replay holds 1 GB or more. The malloc limit also stops an allocation that Apple's code makes and never touches, such as CoreAudio's Vorbis comment reader, in a FLAC or an Ogg file, reserving room for a comment count it then refuses.
- **To reproduce a crash**, run its target's binary on the file: `build/fuzz/libfuzzer/bin/tags-mp3 build/fuzz/crashes/tags-mp3/crash-…`. To shrink it, add `-minimize_crash=1 -runs=100000`.

## Seeds and dictionaries

- **`Seeds/<target>/`** holds small valid files of the target's format, each tagged, some with a picture or a sheet. `make-seeds.sh` makes the audio and pictures from a sine tone and a generated test pattern, so none is anyone's recording. The text seeds are written in the script. Re-run it only to change the seeds, and commit what it writes.
- **`Dictionaries/`** lists each format's magic, chunk, frame, atom, and keyword spellings, which a mutation splices in.

## A crash, once found

1. Minimize it, find its cause, and fix it. A fix to TagLib's own files is a dated row in `third_party/taglib/CHANGES.md`, as MPL 1.1 asks.
2. Add the minimized file to `Regressions/<target>/`, named for what it broke, so `make fuzz-replay` runs it.
3. Add a test that reads it through the piece's API to the piece's own test bundle, so `make test` runs it too.
