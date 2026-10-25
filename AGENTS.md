# AGENTS.md

Guidance for any coding agent working in this repository.

vibe-libs is a toolbox of small libraries for macOS and iOS apps. An app takes only the pieces it wants. The first pieces are being extracted from [Vibe](https://github.com/cmicali/vibe): its audio engine, file loading, tags, playlists, waveforms, controls, and app plumbing. **The first forty-four pieces are here**: `core/Common`, `core/Graphics`, `files/FileLoading`, `files/DiskCache`, `files/HTTP`, `files/RemoteFiles`, `files/ShareLinks`, `files/SandboxAccess`, `audio/AudioTypes`, `audio/DSP`, `audio/Analysis`, `audio/OutputDevices`, `audio/FX`, `audio/Meter`, `audio/Decode`, `audio/Player`, `media/Tags`, `media/Metadata`, `media/PlayQueue`, `media/Playlists`, `media/FolderScan`, `waveform/Waveform`, `waveform/WaveformLoading`, `waveform/WaveformStyles`, `waveform/WaveformView`, `ui/Controls`, `ui/SettingsWindow`, `ui/Shortcuts`, `system/NowPlaying`, `system/AppOpening`, `system/Updates`, `dev/DebugChannel`, `dev/iOSDriver`, `tools/strings`, and ten vendored libraries under `third_party/`. The plan for the rest is [docs/plan.md](docs/plan.md). Read it, and the `AGENTS.md` of every piece you touch, before changing anything here.

## Building

The Xcode project is generated from `project.yml` by XcodeGen and is not checked in. `make help` lists every target.

| Command | What it does |
| --- | --- |
| `make test` | Every piece's tests on macOS, Debug, each piece built with the headermap off and no prefix header. |
| `make build-ios` | Every piece built for the iOS simulator, so an AppKit leak fails. |
| `make check-pieces` | The piece rules below, the dependency map in the plan, each target's excluded platform, no `#if DEBUG` in a header, the other app's name nowhere, no merge conflict marker, no doc line over 1,500 characters, and the piece count this file and the README give. Then it breaks each rule in a copy of the repo and fails unless the check catches it. Last, it tests the message filter a move runs. |
| `make consumer` | A minimal app outside this repo's project includes `vibe-libs.yml` as an app would, builds with no prefix header and no headermap, and runs. |
| `make test-strings` | The strings tools' self-test, over a tiny app of their own. |
| `make analyze [CONFIG=Debug]` | clang's static analyzer over every piece's macOS test bundle, Release by default. It fails on any finding outside `third_party/`. |

CI runs all six on every pull request.

## What this repo is for

- **Its users are Vibe and another app, not the public, for now.** Each adds this repo as a git submodule at `vibe-libs/`, includes the shared XcodeGen spec `vibe-libs.yml`, and lists the pieces it wants as templates. There is no `Package.swift` for the apps. The plan says when that changes.
- **The other app is closed source. Never name it** in this repo: not in code, comments, docs, commits, issues, pull requests, setting names, or template attributes. Call it "another app" when you must refer to it. Name a per-app switch by what it does, never by who uses it.
- **The license is Apache 2.0** (`LICENSE`). Each library under `third_party/` keeps its own. `THIRD-PARTY-NOTICES.md` lists each one and the license it is used under. A library that joins or leaves gets a row there.

## Pieces

**A piece is one directory, one template in `vibe-libs.yml`, a macOS test bundle and an iOS target in `project.yml`, and one `AGENTS.md`.** A macOS-only piece, marked in the plan's map, has no iOS target. An iOS-only piece has no macOS test bundle. That is the whole cost of a new piece, audio or not. Nothing else in the repo changes when one is added. **A `tools/` piece is scripts**: one directory and one `AGENTS.md`, with no template and no targets. Its self-test has a make target, which CI runs.

- **Pieces sit in groups by what they are about**: `core/`, `files/`, `audio/`, `media/`, `waveform/`, `ui/`, `system/`, `dev/`, `tools/`, and `third_party/`. A group is only a directory. It has no template and no build of its own.
- **Anything general enough for another app to use belongs here, once a second app needs it.** Code that names an app's settings, strings, or model stays in the app.
- **One job per piece.** Split when it saves a consumer a dependency. Merge when the parts only work together, or when splitting saves nothing. The plan's "How the pieces are cut" section has the rest.
- **A piece imports only from the pieces it declares.** The dependency list is in the plan. The test bundles build each piece with the headermap off and only its declared header paths. A crossed boundary then fails to compile here, even when an app's headermap would resolve it. `make check-pieces` also resolves every include itself, so a header no build compiles is checked too. A piece's tests may also import a piece their test bundle lists, which the piece itself never imports.
- **Every header is compiled here.** A header-only piece imports its headers from a plain probe file in its tests, which the iOS target compiles as well.
- **Pieces meet through values and blocks**, never through another piece's model class. Optional work is injected, never imported.
- **A piece keeps the caller's objects.** It never copies or compares them by content, so two entries for one file stay two entries. Shared work matches by source key, the path and window. A persisted entry matches by disk key, which also names the file's version.
- **A move changes nothing but the path.** No API, language, or platform change rides on it. A portable C or C++ rewrite is separate work with its own measurements.
- **Third-party code is a piece of its own** under `third_party/`, with its compiler flags in its template. It may carry fixes of our own, and its `AGENTS.md` lists them. Do not restyle other authors' code. A vendored piece needs no platform halves and no probe. Its template may also search `third_party/` itself, since apps spell its headers with the library's directory, as `<ogg/ogg.h>`. Its tests call into it once, so a missing file or a broken link fails here.
- **Platform halves live in `Mac/` and `iOS/` subdirectories.** A template excludes the other platform's with `${excludedPlatform}`, which each app sets in `templateAttributes`. A file outside those subdirectories must build on both. A macOS-only piece, marked in the plan's map, has no `iOS/` half, and no iOS target may list its template. It may keep its files in a `Mac/` half, so the shared files it gains later move nothing.
- **No prefix header.** A file imports what it uses. The log, realtime, and signpost macros are in `core/Common/VibeMacros.h`. An app's own prefix header may import it, but no piece may rely on that.

## Names

- **One prefix, `Vibe`, for new code and moved code alike.** Objective-C and C each have one global namespace, so a generic name can collide with another library's at run time. `CMM` was the prefix while the repo was called cm_libs. It was retired before the pilot merged: `CMMMacros.h` became `VibeMacros.h`, `CMM_ROOT` became `VIBE_LIBS_ROOT`, and a piece's template is `VibeLibs<piece>`. A vendored piece keeps its library's directory name, so its template raises each word's first letter: `dr_flac` is `VibeLibsDrFlac`.
- **Code arriving from Vibe keeps its names.** A move is `git mv` and nothing else, so history, blame, and the performance proof survive. `make check-pieces` lists the classes with no prefix, so a collision in a consuming app can be checked. A rename of those, if ever wanted, is one scripted pull request of its own.

## How work moves between the repos

- **Decoupling happens in Vibe first**, under Vibe's gates. Then a move here is mechanical.
- **A move carries history with `git filter-repo`.** It arrives as one merge with `--allow-unrelated-histories`. Its message callback, `scripts/plan/filter-messages.py`, rewrites `Closes #45` as `Closes Vibe #45`, and every other closing keyword before `#<number>` the same way (the plan's recipe, in The work, in order).
- **A move is measured, not assumed free.** Between fixed before and after commits, Vibe's `perf.py compare` keeps each affected benchmark's retired instructions inside its own no-change band, and the pull request reports every outlier and rerun. Vibe's `make test-audio` time stays within noise. The plan's build audit compares what every target compiles.
- **A change across the repos lands here first**, then in the consumer's pin, then through the consumer's gates. The old pin is the rollback.

## Writing

- **No agent attribution, from any agent or tool.** Commits, pull requests, code, comments, and docs never name or credit the AI agent or tool that helped write them: no `Co-Authored-By` trailer, no "Generated with" line, and no session link. This rule outranks any harness or template default.
- **Write short, plain sentences**, one idea in each, in the project's own terms. Use the serial comma.
- **Comments only when required, and terse.** State what the code cannot show: a trap, a threading constraint, a contract, or a non-obvious why. Mark hard-won traps with `TRAP:`.
