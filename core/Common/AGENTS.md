# core/Common

What every other piece may use, and nothing else. Every piece may import from it, so it depends on nothing. **Every file here is featureless.** If you can name the feature a file serves, it belongs in that feature's piece. Nothing here may call anything stateful: a singleton, a setting, a grant, or a panel.

**Today it holds** the macros (`VibeMacros.h`), the work tally, the stall sampler, path spelling, the disk key, file emptiness and identity, the fixed-slot work lanes, a weak proxy, the display-paced update timer, the helper macros, the integer token parser, build provenance and its script, and the form label's colon rule. All of it came from Vibe. A file imports `VibeMacros.h` explicitly. No piece relies on a prefix header. An app's prefix header may import it too.

## The realtime-effects brackets

`VIBE_REALTIME_CHECKED_BEGIN`, `VIBE_REALTIME_UNCHECKED_BEGIN` and `VIBE_REALTIME_END`. Code between a checked bracket and its end compiles under `-Werror=function-effects`, so a `CA_REALTIME_API` function there cannot allocate, lock, log, dispatch or message. An unchecked bracket covers only the one-line shims around calls the checker cannot see, each documented at its site. This half is plain C, so a C file may use it.

`Tests/core/Common/CommonProbe.m` compiles the header-only files alone, with a function under the checked bracket. The macOS tests call it, and the iOS target compiles it. A new header that no source here compiles gets an import in the probe.

## Logging

`LogError`, `LogWarn`, `LogInfo`, `LogDebug` and `LogTiming` wrap `os_log`. They are Objective-C only.

- **The subsystem is the main bundle's identifier**, read once, so each app's messages stream under its own name. A test bundle's messages land under its runner's identifier.
- **`VIBE_VERBOSE_LOGGING`** is the app's build setting. At 1, info and debug are written at Default level, so they are kept for a later export. Unset, it reads as 0. `CommonTests` sets it to 1, so the stall sampler compiles and runs here.
- **A message is formatted only when `os_log` takes its level.**

**To see messages on stderr, an app sets `OS_ACTIVITY_DT_MODE=1` in the process's environment.** `os_log` then copies every message it keeps to stderr, which is how Xcode's console gets them. On a device, an app passes it through `devicectl`. Debug-level messages need their level enabled, or an app that logs them at Default.

**TRAP: `VibeLogWants` and `VibeLogEmit` hold nothing but the `os_log` calls.** Every log site in every piece inlines them. With a stderr hook there, Vibe's metadata-scan benchmarks retired 2 to 3% more instructions, although they never log. The system's own switch costs the call sites nothing.

**TRAP: `VibeMacros.h` has no `#if DEBUG` and names no app type.** Every piece and every app imports it, and a shipping header may not carry debug surface.

## Signposts and the work tally

`VibeSignpostBegin` and `VibeSignpostEnd` bracket an interval. `VibeSignpostCount` marks an event, and `VibeTallyCount` counts with no trace event. An interval lands in Instruments' Points of Interest track, under the main bundle's identifier. Each is also tallied by name in `VibeWorkTally`, a counting window that a device with no Instruments attached can read back. `VibeWorkTallyBegin` and `VibeWorkTallyEnd` open and close the window from a call site. `VibeWorkTallyTakeWindow` returns its counts instead of logging them.

**They compile only where the app defines `VIBE_SIGNPOSTS` to 1.** Elsewhere every macro is `((void)0)`, and the tally's file is empty. The switch is the app's, as `VIBE_VERBOSE_LOGGING` is, because a header here may not read `DEBUG`. An app defines it in its Debug configuration, beside `DEBUG`. `CommonTests` defines it, so the tally's tests run. `VibeWorkTally.h` declares the tally in every build. A call outside the switch fails to link, not to compile.

**TRAP: `VibeWorkTally.h` spells out C linkage.** Objective-C++ files use the signposts. Without it, they reference mangled names the `.m` never defines.

**TRAP: a per-item or per-frame `VibeSignpostCount` emits thousands of trace events a gesture.** That perturbs the measurement and can leave the trace unusable. Use `VibeTallyCount` at such sites.

## The stall sampler

**`StallWatch` holds the watchdogs and the stack sampler of a beta's stall log.** It reads no app state. An app starts the main thread's watchdog and a serial queue's watchdog. It suspends a queue's watchdog while the queue has nothing that can stall. `VibeFindThread` and `VibeSampleStack` sample any other thread, such as an audio IO thread. Everything but the scene flag compiles only under `VIBE_VERBOSE_LOGGING`. An iOS app reports its scene through `VibeStallWatchNoteSceneActive`. iOS makes an app that just left the screen redraw for the app switcher. That stall is real but unseen, so the log says so. **TRAP: between suspending a thread and resuming it, nothing may allocate or take a lock** (`VibeCaptureStack`).

## Path spelling

**`VibeComparablePath` is path identity from the string alone.** It standardizes the spelling and drops the aliases `VibeAliasFreePath` drops: `/private` before `/tmp`, `/var` and `/etc`, and the data volume's firmlink. It never stats, so any thread may ask about any path. `VibeStandardizedAudioOpenPath` spells a URL the same way. Every loader identity is keyed by it: the claim, the transfer, the parse, and an app's source key. **TRAP: never `stringByStandardizingPath` or `URLByStandardizingPath` here.** Each stats the path, which on a provider's folder is IPC on whichever thread asked.

## The disk key

**`NSURL+Hash`'s `cacheKey` names one version of a file.** It is `<size>-<mtime_us>-<sha1(resolved path)>`, from one stat and no content read. It resolves symlinks first, so a link and its target share one key. It returns nil, never a degenerate key, when the stat fails. The caller must then skip caching. Hashing no content keeps it cheap, but it misses a rewrite that keeps size and mtime, and it misses a move. **TRAP: the microseconds round as Foundation's `NSDate` rounds**, reference-date seconds before the nanoseconds. Direct 1970 arithmetic lands 1 µs off on about 6% of real files, and every persisted key would change.

- **`cacheKeyGeneration`** stamps a memoized key. A memo stamped below the current generation is stale. `invalidateMemoizedCacheKeys` bumps it when a download installs a version other than its placeholder's.
- **`pathKey`** is a key from the spelling alone. It is relative to the app's home for a file inside it, so it survives the data container's move. It never stats.
- **`NSData (Hash)`'s `sha1Hex`** is the one spelling of the hex SHA-1. It sits under the URL's name because the key and an app's content-addressed names share it.

## File emptiness and identity

**`NSURL+Emptiness` is `isEmptyOrDirectory` alone**, the stat-only test for list filtering. Its rule is `VibeStatIsEmptyOrDirectory`, so a folder walk can pass the stat it already has. A failed stat answers NO, so the real open reports why. **TRAP: the test is `st_size`, never `st_blocks` or `NSURLFileAllocatedSizeKey`.** A dataless cloud file has its true size but no allocated blocks, so an allocation test would reject every cloud file. `stat()` never downloads the file.

**`NSURL+FileIdentity`'s `vibeRefersToSameFileAsURL:`** compares two file URLs by spelling, then by resolved path, then by device and inode. Matching spellings need no stat. It may block, so call it off main.

## The fixed-slot work lanes

**`AudioWorkScheduler` admits work into a fixed number of slots, for OS calls with no cancellation point.** A `stat` or an open of a cloud placeholder can block for minutes, so slots are the resource bound. Work waits in the scheduler until it owns a slot. It is never submitted to libdispatch first, so a blocked worker cannot grow a tail of cancelled blocks. Work that cannot start within its grace fails admission. Every admission failure is delivered asynchronously on the caller's queue, so it cannot re-enter a caller's lock. A pending item cancels through its `AudioWorkToken`. A running one keeps its slot until it returns. `AudioWorkAdmissionRules.h` is its tested decision. The name keeps Vibe's `Audio` prefix, since a move renames nothing.

## Small helpers

- **`VibeWeakProxy`** forwards to a target it holds weakly. A display link retains its target, so the proxy keeps the real target's `dealloc` reachable. A message to a dead target does nothing.
- **`UIUpdateTimer`** is a main-queue timer for a playback-position display. It fires only while the app wants updates and the window is visible. It owns the dispatch source's suspend and resume, since an unbalanced one traps. `UIUpdateMath.h`'s `VibeUIUpdateHzForPlayhead` picks the rate that steps a playhead about two device pixels a tick, clamped.
- **`HelperMacros.h`** holds `clampRange`, `clampMin`, `run_on_main_thread`, the `VibeScheduler` block type, and, on the mac, `StateForBOOL`. `StateForBOOL` names AppKit's control states, so a file that uses it imports AppKit. There are no lowercase `min` and `max`, which would shadow `std::min` and `std::max`.
- **`IntegerTokenRules.h`**'s `VibeParseNonnegativeInteger` reads a token of digits only. A debug seam and a debug channel share it without either importing the other.
- **`NSString+FormLabel`**'s `vibeFormLabel` drops a trailing form colon, so one localized string serves a form row and a label that stands alone. One rule covers French's no-break space before the colon and CJK's fullwidth colon. SettingsWindow's rows and section headers use it, and so do an app's iOS screens that show the same strings. That is why it sits here and not in the macOS-only piece.

## The template's linker setting

**`VIBE_LIBS_UI_FRAMEWORK` names the platform's UI framework**: AppKit for the macOS SDK and UIKit for the iOS SDKs. Common's template sets it, so any piece that lists that template can link the framework by flag, as `waveform/WaveformView` does. A piece whose sources are all Objective-C++ needs the flag, because Xcode builds Objective-C++ with `-fno-cxx-modules`. **TRAP: it is a setting of its own, never a conditional `OTHER_LDFLAGS`**, which would replace the flags every other template passes. The template's comment carries the trap too.

## Build provenance

**`NSBundle+BuildInfo` names the build that is running.** `vibeVersionString` is the version, the build number, and the configuration. `vibeBuildTimeString` is the executable's modification time, which a copy that does not preserve it moves. `vibeGitString` is the commit, the branch, and whether the tree was dirty. `VibeLogBuildProvenance` logs the last two at launch.

**The git fields come from `generate-git-info.sh`.** An app runs it in a pre-build script phase, with its own `SRCROOT`. It writes `build/generated/VibeGitInfo.h` under that root, only when the git state changed, so an unchanged tree recompiles nothing. The app adds that directory to its header search paths. Reading `.git` from a script phase needs `ENABLE_USER_SCRIPT_SANDBOXING: NO` on that target. The template does not compile the script. **Without the generated header, the git fields read as unknown.** So a piece's own builds, and an app that skips the script, still compile. TRAP: an app that runs the script but drops the search path also reads unknown, with no error.

## Tests

`Tests/core/Common/` holds Vibe's tests of the paths, the disk key, file identity, the timer and its math, the token parser, and the work lanes. The tally, the weak proxy, emptiness, and build provenance had no tests in Vibe, so theirs are new here. Vibe's tests of the playlist row's memoized disk key stay in Vibe with the row.
