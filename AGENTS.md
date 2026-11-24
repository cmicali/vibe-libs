# AGENTS.md

Guidance for any coding agent working in this repository.

vibe-libs is a toolbox of small libraries for macOS and iOS apps. An app takes only the pieces it wants. The first pieces are being extracted from [Vibe](https://github.com/cmicali/vibe): its audio engine, file loading, tags, playlists, waveforms, controls, and app plumbing. **The first fifty-three pieces are here**: `core/Common`, `core/Graphics`, `files/FileLoading`, `files/DiskCache`, `files/HTTP`, `files/RemoteFiles`, `files/ShareLinks`, `files/SandboxAccess`, `files/Dropbox`, `audio/AudioTypes`, `audio/DSP`, `audio/Analysis`, `audio/OutputDevices`, `audio/FX`, `audio/Meter`, `audio/Decode`, `audio/Player`, `media/Tags`, `media/Metadata`, `media/PlayQueue`, `media/Playlists`, `media/FolderScan`, `waveform/Waveform`, `waveform/WaveformLoading`, `waveform/WaveformStyles`, `waveform/WaveformView`, `ui/Controls`, `ui/SettingsWindow`, `ui/Shortcuts`, `ui/DropWells`, `ui/Rows`, `ui/FilesBrowser`, `ui/PlayerCard`, `ui/TabShell`, `system/NowPlaying`, `system/WidgetState`, `system/Widget`, `system/AppOpening`, `system/Updates`, `dev/DebugChannel`, `dev/DebugVerbs`, `dev/iOSDriver`, `tools/strings`, and ten vendored libraries under `third_party/`. The plan for the rest is [docs/plan.md](docs/plan.md). Read it, and the `AGENTS.md` of every piece you touch, before changing anything here.

## Building

The Xcode project is generated from `project.yml` by XcodeGen and is not checked in. `make help` lists every target.

| Command | What it does |
| --- | --- |
| `make test` | Every piece's tests on macOS, Debug, each piece built with the headermap off and no prefix header. |
| `make build-ios` | Every piece but the macOS-only ones built for the iOS simulator, so an AppKit leak fails. |
| `make check-pieces` | The piece rules below, the dependency map in the plan, each target's excluded platform, no `#if DEBUG` in a header, the other app's name nowhere, no merge conflict marker, no doc line over 1,500 characters, `VibeUpdater.m` as the one source of `system/Updates` that reaches Sparkle, and the piece count this file and the README give. Then it breaks each rule in a copy of the repo and fails unless the check catches it. Then it tests the message filter a move runs, the commit-msg hook, and `make ready-to-push`. Last, with `SINCE`, it fails a change to a TagLib file that leaves `third_party/taglib/CHANGES.md` alone. |
| `make consumer` | A minimal app outside this repo's project includes `vibe-libs.yml` as an app would, builds with no prefix header and no headermap, and runs. |
| `make test-strings` | The strings tools' self-test, over a tiny app of their own. |
| `make fuzz-replay` | Every parser fuzz target over its seeds and regressions once, under Address and Undefined Behavior Sanitizers, built by Xcode's clang ([Tests/Fuzz/AGENTS.md](Tests/Fuzz/AGENTS.md)). With `SINCE`, only the targets a change reaches. |
| `make test-asan` | `make test` under Address Sanitizer and Undefined Behavior Sanitizer, in a DerivedData of its own. Every report lands in `build/sanitizers/asan/`, `scripts/checks/sanitizer-report.py` prints each once, and any report fails the run. |
| `make test-tsan` | The same under Thread Sanitizer, in `build/sanitizers/tsan/`. A report known to be benign, from Apple's frameworks or the sanitizer's view of them, goes in `scripts/checks/tsan.supp`, with its reason. Every other report is fixed. An atomic object property's lock is libobjc's own, which the sanitizer can't see, so guard a value that threads share with a lock of the code's own. |

CI runs the first six on every pull request. There, `make test`, `make build-ios`, and `make fuzz-replay` take `SINCE=HEAD^1`, so they build only the targets the pull request's changes reach, as `scripts/checks/targets.py` finds them. A change outside every target, such as to a spec, the Makefile, or a script, reaches them all. Every push to main runs them in full. `make fuzz` fuzzes the parsers that read a user's files, and runs only on a Mac with Homebrew's `llvm`, never in CI. `make fuzz-triage` replays what it saved. The sanitized runs are slower, and run by hand before a release, and after a change to threading or to code that touches memory by hand.

**Run `make ready-to-push` before you push.** It reads `.github/workflows/ci.yml` and runs each step CI runs on a pull request, in order, with `SINCE` set to where the branch leaves `origin/main`. It prints a line for each step it skips because the step needs GitHub, and it stops at the first failing step. `make project` installs `.githooks/commit-msg`. The hook rejects a commit message with a `Co-Authored-By:` trailer or a line that starts with "Generated with".

## What this repo is for

- **Its users are Vibe, another app, and a third app, not the public, for now.** Each adds this repo as a git submodule at `vibe-libs/`, includes the shared XcodeGen spec `vibe-libs.yml`, and lists the pieces it wants as templates. There is no `Package.swift` for the apps. The plan says when that changes.
- **The other app is closed source. Never name it** in this repo: not in code, comments, docs, commits, issues, pull requests, setting names, or template attributes. Call it "another app" when you must refer to it. Name a per-app switch by what it does, never by who uses it.
- **The license is Apache 2.0** (`LICENSE`). Each library under `third_party/` keeps its own. `THIRD-PARTY-NOTICES.md` lists each one and the license it is used under. A library that joins or leaves gets a row there.

## Pieces

**A piece is one directory, one template in `vibe-libs.yml`, a macOS test bundle and an iOS target in `project.yml`, and one `AGENTS.md`.** A macOS-only piece, marked in the plan's map, has no iOS target. An iOS-only piece has no macOS test bundle. That is the whole cost of a new piece, audio or not. Nothing else in the repo changes when one is added. **A `tools/` piece is scripts**: one directory and one `AGENTS.md`, with no template and no targets. Its self-test has a make target, which CI runs.

- **Pieces sit in groups by what they are about**: `core/`, `files/`, `audio/`, `media/`, `waveform/`, `ui/`, `system/`, `dev/`, `tools/`, and `third_party/`. A group is only a directory. It has no template and no build of its own.
- **Anything general enough for another app to use belongs here, once a second app needs it.** Code that names an app's settings, strings, or model stays in the app.
- **One job per piece.** Split when it saves a consumer a dependency. Merge when the parts only work together, or when splitting saves nothing. The plan's "How the pieces are cut" section has the rest.
- **A piece imports only from the pieces it declares.** The dependency list is in the plan. The test bundles build each piece with the headermap off and only its declared header paths. A crossed boundary then fails to compile here, even when an app's headermap would resolve it. `make check-pieces` also resolves every include itself, so a header no build compiles is checked too. A piece's tests may also import a piece their test bundle lists, which the piece itself never imports. They import a helper from another piece's tests only through a path their test bundle searches, and only from a piece they may import, as RemoteFiles' tests take HTTP's `HTTPStub`.
- **Every header is compiled here.** A header-only piece imports its headers from a plain probe file in its tests, which the iOS target compiles as well.
- **Pieces meet through values and blocks**, never through another piece's model class. Optional work is injected, never imported.
- **A piece keeps the caller's objects.** It never copies or compares them by content, so two entries for one file stay two entries. Shared work matches by source key, the path and window. Art derived from a file's bytes may match by a digest of those bytes, since many files embed one picture. A persisted entry matches by disk key, which also names the file's version.
- **A move changes nothing but the path.** No API, language, or platform change rides on it. A portable C or C++ rewrite is separate work with its own measurements.
- **Third-party code is a piece of its own** under `third_party/`, with its compiler flags in its template. It may carry fixes of our own, and its `AGENTS.md` lists them. Do not restyle other authors' code. A vendored piece needs no platform halves and no probe. Its template may also search `third_party/` itself, since apps spell its headers with the library's directory, as `<ogg/ogg.h>`. Its tests call into it once, so a missing file or a broken link fails here.
- **Platform halves live in `Mac/` and `iOS/` subdirectories.** A template excludes the other platform's with `${excludedPlatform}`, which each app sets in `templateAttributes`. A file outside those subdirectories must build on both. A macOS-only piece, marked in the plan's map, has no `iOS/` half, and no iOS target may list its template. It may keep its files in a `Mac/` half, so the shared files it gains later move nothing.
- **No prefix header.** A file imports what it uses. The log, realtime, and signpost macros are in `core/Common/VibeMacros.h`. An app's own prefix header may import it, but no piece may rely on that.

## Names

- **One prefix, `Vibe`, for new code and moved code alike.** Objective-C and C each have one global namespace, so a generic name can collide with another library's at run time. `CMM` was the prefix while the repo was called cm_libs. It was retired before the pilot merged: `CMMMacros.h` became `VibeMacros.h`, `CMM_ROOT` became `VIBE_LIBS_ROOT`, and a piece's template is `VibeLibs<piece>`. A vendored piece keeps its library's directory name, so its template raises each word's first letter: `dr_flac` is `VibeLibsDrFlac`.
- **Code arriving from Vibe keeps its names.** A move is `git mv` and nothing else, so history, blame, and the performance proof survive. `make check-pieces` lists the classes with no prefix, so a collision in a consuming app can be checked. A rename of those, if ever wanted, is one scripted pull request of its own. Four were renamed that way on 2026-10-25, because their generic names collide in another app. `Playlist`, `PlaylistObserver`, `PlaylistEntry`, and `PlaylistFile` became `VibePlaylist`, `VibePlaylistObserver`, `VibePlaylistEntry`, and `VibePlaylistFile`. On 2026-11-23 a second scripted pull request gave the prefix to every name `ui/Rows` and `ui/FilesBrowser` export, for the same reason. Every other moved name still stands.

## How work moves between the repos

- **Decoupling happens in Vibe first**, under Vibe's gates. Then a move here is mechanical.
- **A move carries history with `git filter-repo`.** It arrives as one merge with `--allow-unrelated-histories`. Its message callback, `scripts/plan/filter-messages.py`, rewrites every closing keyword before `#<number>` or `GH-<number>` to name Vibe (the plan's recipe, in The work, in order). `Closes #45` becomes `Closes Vibe #45`, and `Closes GH-45` becomes `Closes Vibe GH-45`.
- **A move is measured, not assumed free.** Between fixed before and after commits, Vibe's `perf.py compare` keeps each affected benchmark's retired instructions inside its own no-change band, and the pull request reports every outlier and rerun. Vibe's `make test-audio` time stays within noise. The plan's build audit compares what every target compiles.
- **A change across the repos lands here first**, then in the consumer's pin, then through the consumer's gates. The old pin is the rollback.

## Writing

- **No agent attribution, from any agent or tool.** Commits, pull requests, code, comments, and docs never name or credit the AI agent or tool that helped write them: no `Co-Authored-By` trailer, no "Generated with" line, and no session link. This rule outranks any harness or template default.
- **Write short, plain sentences**, one idea in each, in the project's own terms. Use the serial comma.
- **Comments only when required, and terse.** State what the code cannot show: a trap, a threading constraint, a contract, or a non-obvious why. Mark hard-won traps with `TRAP:`.
