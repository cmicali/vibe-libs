# vibe-libs: the plan

**Status: planned 2026-10-17 and revised after review. Phase 0 done on 2026-10-18. Phase 1, the pilot, merged on 2026-10-20: this repo's first pieces and Vibe's pull requests #314 and #315. Revised again on 2026-10-18 after a second review: the checker covers every rule it promised, FolderScan and Playlists join the first path, and four contracts and a delivery list are written down. Revised on 2026-10-20 after a third review: the shell pieces join on a second track for a third app, the one prefix is `Vibe`, and a macOS-only piece has a shape. Wave 1 merged on 2026-10-21: `core/Graphics` moved (#6, Vibe #350), and seam 13 landed (Vibe #351). Waves 2 and 3 merged on 2026-10-21: `ui/Controls` and `ui/SettingsWindow` moved (#9, #11), and seams 14 to 18, the queue half of 19, 22, and 23 landed (Vibe #353 to #359). Wave 4 merged on 2026-10-21 with Phase 3 steps 1 and 2, cut 30, and the waveform version check (Vibe #361 to #364, this repo's #13 and #14). Wave 5 merged on 2026-10-21 with Phase 3 steps 3 and 4, the shell track's last move, and the metadata version check (Vibe #366 to #369, this repo's #16 to #18). Wave 6 merged on 2026-10-21 with all of Phase 3 step 5 but Player: OutputDevices, FX, Meter, Decode, and Analysis (Vibe #371 to #374, this repo's #20 to #23).**

**Waves 7 to 9 merged on 2026-10-22 with the rest of Phase 3's moves and NowPlaying: Player, the five media pieces, the four waveform pieces, Controls' indicators, and `tools/strings` (Vibe #378 to #391, this repo's #28 to #42). Wave 10 merged on 2026-10-23 and brought the pieces to 44: DebugChannel and iOSDriver, HTTP, RemoteFiles, and ShareLinks, Updates and Sparkle, SandboxAccess, and AppOpening (Vibe #393 to #397, this repo's #44 to #48). Wave 11 merged on 2026-10-23. The pitch fader joined `ui/Controls` (Vibe #399, this repo's #51). The Phase 3 consumer was met (this repo's #50). Phase 4, the tag fields, was done (Vibe #400, this repo's #52).**

**Closing status, 2026-10-23: every planned move is done.** Phase 3's done-when is met, and so is Phase 4. The tree holds 44 pieces. The catalog scan was done on 2026-10-23 (this repo's #56, Vibe #405). What remains is Phase 5. This replaces the plan of 2026-10-09, written when the repo was called PlaybackKit.

**Status, 2026-10-25: the final batch of review fixes landed.** It came as four pairs: the app-specific names (#57, Vibe #406), the tests and fakes (#60, Vibe #407), the cache signals (#58, Vibe #408), and the app policy that left the pieces (#59, Vibe #409). Then one pair renamed the four generic playlist types (#61, Vibe #410). The closing pass over the docs is this repo's #62.

**Status, 2026-10-26: follow-ups landed** in this repo's #63 to #69. The debug channel answers a command written before it installs, serves the oldest command first, and keeps macOS from napping the app. The Now Playing record became a class. `HTTPStub` moved to HTTP's tests. The touch driver's files took names that name no app.

vibe-libs is a toolbox of small libraries for macOS and iOS apps. An app takes only the pieces it wants. The first pieces come from [Vibe](https://github.com/cmicali/vibe): its audio engine, file loading, tags, waveform data and drawing, and the third-party code it vendors. Anything else in Vibe that another app could use is a candidate. **A candidate moves when a second app needs it**, so the toolbox grows from real reuse.

Its users are Vibe and another app. Both add it as a git submodule.

## Decided

- **The name is vibe-libs, and the one prefix is `Vibe`**, for moved code and new code alike. `CMM` came from the name cm_libs, which is gone, and every moved class already carries `Vibe`. It was retired in one commit on the pilot's branches, before they merged: `CMMMacros.h` became `VibeMacros.h`, `CMM_ROOT` became `VIBE_LIBS_ROOT`, a piece's template is `VibeLibs<piece>`, and the checker and the consumer followed.
- **Code moved from Vibe keeps its names.** A move is `git mv` and nothing else. The `Vibe` C prefix stays. Four names were renamed on 2026-10-25, in one scripted pull request of their own, because their generic names collide in another app. `Playlist`, `PlaylistObserver`, `PlaylistEntry`, and `PlaylistFile` took the `Vibe` prefix. Every other moved name still stands.
- **One repo of many pieces, grouped by what they are about.** An app picks pieces, not the whole repo.
- **Apps compile the pieces' sources in their own targets**, through templates in a shared XcodeGen spec. No static libraries and no Swift package for the apps, for now.
- **Third-party code is a piece of its own**, one per library.
- **Extraction first, everything else after.** A move changes no API, no language, and no platform. Portable C or C++ rewrites, new tag fields, and other redesigns are separate work with their own scope and measurements.
- **The playback and waveform path moves first, with FolderScan and Playlists.** The other app builds its first slice on them. Every other piece follows demonstrated reuse. [What the other app needs, and when](#what-the-other-app-needs-and-when) is the one list of its deliveries.
- **Vibe's waveform engine (PR #294) merged in Vibe before any move**, so the waveform data moves once.
- **The shell pieces move on a second track, beside Phase 2.** A third app, a mac app that plays no audio, needs the settings window, the mac controls, the typography slots, and remappable shortcuts. They touch none of the first path's files, so they wait on nothing in it. [The shell pieces](#the-shell-pieces) says what moves and what is cut first, and [the shell track](#the-shell-track-beside-phase-2) the order.
- **The license is Apache 2.0**, Vibe's own, so code moves between the repos under the terms it already has.
- **This plan is the authority** for the pieces, what each owns, and the shared milestones. Vibe's plan covers only Vibe's own edits.

### What changed from the 2026-10-09 plan

| Was | Now | Why |
| --- | --- | --- |
| PlaybackKit, prefix `PBK` | vibe-libs, one prefix `Vibe` (`CMM` from 2026-10-17 to 2026-10-20) | The repo is a toolbox, not only playback, and the moved code already carries `Vibe`. |
| Four products cut along Vibe's directories | Pieces with one job each | Each piece should be usable without its neighbors. |
| Rename every class and C symbol on the move | No rename on the move | A rename touches 441 names in 678 files of Vibe and 88 of #294's 111 files. Folded into the move, it would turn every moved file into a content change and break the performance proof. Four generic names took the `Vibe` prefix on 2026-10-25, in a scripted pull request of their own, because they collide in another app. Every other moved name still stands. |
| Static framework targets in the shared spec | Templates the app compiles in | Same run time, and the app's test targets can still build the code with their own flags (below). |
| A prefix header per product | Explicit imports of one macros header | A target has one prefix header, so a piece cannot bring its own. |
| Vendored code inside the engine product | Each library a piece of its own | An app can take TagLib or dr_flac without the engine. |

## How the pieces are cut

1. **One job per piece, named for the job.** Ask whether someone would want it without its neighbors.
2. **Split when it saves a consumer a dependency. Merge when the parts only work together, or when splitting saves nothing.** Tempo and key detection are one piece, because they share their framing and depend on nothing but the key's type. Tags and Metadata are two pieces, because a tag reader should not drag in the cache, the scan, and the decoders.
3. **A piece's code lives with the piece that reaches into it.** The morph engine is used by the renderers, so it sits with the styles. The device categories on `AudioPlayer` read the player's private state, so they sit in `Player/Mac` and `Player/iOS`. The device and session classes they call do not, so those are their own piece.
4. **Pieces hold the caller's objects, never another piece's model class.** A playable item is any object that adopts a small protocol giving its file, its frame window, its source key, and its disk key. Vibe's `AudioTrack` adopts it. The player, the caches, and the queue keep the caller's object and hand the same one back. A piece that writes results into an item declares a protocol of its own for that, as Metadata does (seam 22). Four identities stay separate:
   - **Source identity** is the source key: the file's path and its window. It names the same stretch of audio, so shared work and claims match on it. It does not change when the file's contents do, so it cannot tell a late result from an old version.
   - **Version identity** is the disk key: `core/Common`'s `cacheKey` (`NSURL+Hash`), built from the file's size, modification time, and resolved path, with the window appended for a waveform. It names one version of the file, so persisted entries match on it. An item may memoize it. Each memo is stamped with a generation kept on the disk key's own category, `NSURL (Hash)`. When a download installs a new version, FileLoading bumps the generation. Every older memo then computes the key again. The waveform cache checks the version at a decode's completion (Vibe #362). The metadata loader checks it at a parse's completion, drops a result read from another version, and parses that file again under the new key (Vibe #367). A new version's answer replaces what the holder installed, since the holder refuses only a successful answer of the same version.
   - **Entry identity** is the caller's object. Two entries for the same file are two entries.
   - **Submission identity** is the player's own counter for each play. It decides which settlement is current.

   **A late result carries the version it was read from.** A metadata or waveform job records the disk key when it is submitted. Before a receiver installs or files the result as an item's current data, it compares that key with the item's current one. On a mismatch it drops the result. The cache may still file it under its own disk key, which names the old version. The source already sounding keeps the version it opened, and its transport still settles by submission identity.
5. **Optional work is injected, never imported.** Analyzers ride the waveform decode as observers. Folder art takes its switch and its access check as providers. The file loader takes the opener of the handle it serves.
6. **Every piece is Objective-C or Objective-C++ on Apple's frameworks when it moves.** `waveform/Waveform` is C++, but it calls Accelerate and Compression too. Making any piece portable is a later rewrite with its own measurements (see Later).
7. **Policy stays in apps.** That means which files count as playable, what plays next under which settings, every display string, and every setting. The tree puts `PlayableExtensions` in AudioTypes, and FileLoading's `readsRemotePlaceholderByRange:` now reads it to decide which files' tags read by range. The maintainer decides whether that list means what the decoders open, or becomes a list the app injects.
8. **Fakes live with what they fake.** The manual render pump lives in Player, and the fake cloud in FileLoading. The fake of ranged HTTP serving lives in HTTP. The fake web server, which imitates Dropbox, Google Drive, and iCloud over that engine, lives in ShareLinks. A test double lives with the tests of what it fakes: HTTP's tests hold `HTTPStub`.

## The pieces

**●** marks the first path: playback, the waveform, and the folder scan, which move first. **○** marks the shell track, which moves beside Phase 2. The other pieces are candidates that move when a second app needs them. What each piece depends on is listed once, in the dependency map below.

```
vibe-libs/
├── AGENTS.md  README.md  LICENSE  docs/plan.md
├── vibe-libs.yml        the shared spec: one targetTemplate per piece with code
├── project.yml          this repo's own project: one headermap-off test bundle per piece
├── Makefile  .github/workflows/ci.yml  scripts/checks/check-pieces.py
├── scripts/plan/derive-deps.py   re-derives the dependency map from a Vibe checkout's imports
├── scripts/plan/filter-messages.py   a move's message callback for git filter-repo
│
├── core/
│   ├── Common ●○        log, realtime-check and signpost macros; stall sampler, work tally;
│   │                    path spelling and comparison, file identity and emptiness; the disk
│   │                    key from a file's attributes; fixed-slot work lanes; a weak proxy; a
│   │                    display-paced update timer; helper macros; the integer token parser;
│   │                    build provenance and its script; the form label's colon rule, on
│   │                    the shell track
│   └── Graphics ●○      image and color aliases, bounded image decode, hex, blend and OKLCH
│                        colors, dominant color, blur, dark-mode helpers; Mac/ the typography
│                        slots (Fonts), on the shell track
│
├── files/
│   ├── FileLoading ●    from a path to readable bytes: placeholder checks, downloads, reading
│   │                    a file while it downloads, read-ahead on network mounts, progress, the
│   │                    transfer registry, one shared download and open per file, and the
│   │                    fake cloud
│   ├── DiskCache ●      a bounded disk cache over PINCache
│   ├── HTTP             ranged HTTP transfers, and a fake of ranged serving
│   ├── RemoteFiles      a local placeholder for a file on a server, fetched by range
│   ├── ShareLinks       Dropbox, Google Drive and iCloud share links turned into direct URLs,
│   │                    the rules for opening any web link, and the fake web server that
│   │                    stands in for those services in tests
│   └── SandboxAccess    macOS only: security-scoped bookmarks and folder grants, with the
│                        grant panel
│
├── audio/
│   ├── AudioTypes ●     the words every audio piece shares: file format identifiers, the
│   │                    extensions the decoders open, the CUE window math, the musical key,
│   │                    and the playable-item protocol
│   ├── DSP ●            varispeed, resampler, fades
│   ├── Analysis ●       tempo and musical key from PCM, and the framing they share
│   ├── Decode ●         open a file or a frame window of it, and read PCM; write PCM to a
│   │                    new file
│   ├── Meter ●          live band levels from inside a render, only while someone looks
│   ├── FX ●             the DJ chain over Apple's audio units
│   ├── OutputDevices ●  Mac/ device discovery, rates, hog mode, format rules, event log;
│   │                    iOS/ the audio session and its route rules
│   └── Player ●         the transport, the voice bus, the master bus, the output unit,
│                        prefetch, gapless, crossfades, open deadlines; Mac/ binding to a
│                        device and bit-perfect output; iOS/ route recovery
├── media/
│   ├── Tags ●           TagLib fields and embedded art bytes
│   ├── Metadata ●       the tag record, the CoreAudio fallback, the cache, the background
│   │                    scan, embedded art and thumbnails, and covers beside the files
│   ├── PlayQueue ●      play order, shuffle, repeat, and what follows a track's end, over
│   │                    opaque entries of the app's own
│   ├── Playlists ●      CUE sheets, also embedded in FLAC, and M3U, read and written as records
│   └── FolderScan ●     walk folders and links into files and CUE rows, and scan a catalog
│
├── waveform/
│   ├── Waveform ●       the summary, pyramid, deep zoom, raster, and archive, in C++;
│   │                    beside them, in Objective-C++, the AudioWaveform name, the mono
│   │                    mix, and CodableAudioWaveform
│   ├── WaveformStyles ● each style's look: its columns, levels, colors, zoom math, and the
│   │                    morph engine that eases between them
│   ├── WaveformLoading ● a file decoded into a summary, with observers on the same pass,
│   │                    cached and shared
│   └── WaveformView ●   the layer host, the macOS view, the iOS scrubber
│
├── ui/
│   ├── Controls ●○      loading bar and pill, equalizer bars; Mac/ the symbol button, the drawn
│   │                    slider and switch, the detent slider, the pitch fader and its panel,
│   │                    the image views, the link label, and the resize timing an app's
│   │                    windows share
│   ├── SettingsWindow ○ macOS only: the System Settings shape, a sidebar with search, back
│   │                    and forward history, the pane base, and the form views: cards, rows,
│   │                    captions, lists, color-pair wells, sliders with readouts; the
│   │                    walker's debug seam
│   └── Shortcuts ○      macOS only: a shortcut as a key code or character with modifiers,
│                        its matching, its name and key equivalent under the current
│                        layout, and the recorder pane over rows the app supplies
│
├── system/
│   ├── NowPlaying       Now Playing info and remote commands, fed the track's values
│   ├── AppOpening       on the mac, one open request from the batches Launch Services
│   │                    splits it into, delivered in order
│   └── Updates          Sparkle for a direct-download build, compiled out of an App Store build
│
├── dev/
│   ├── DebugChannel     drive and inspect a running debug build from a script
│   └── iOSDriver        taps, drags and pinches in the iOS simulator, for scripts; iOS only
│
├── tools/strings ●      the strings registry's extraction and catalog checks, configured per app
│
├── third_party/         taglib/ ●  dr_mp3/ ●  dr_flac/ ●  dr_wav/ ●  r8brain/ ●  PINCache/ ●  PINOperation/ ●
│                        ogg/ ●  vorbis/ ●  Sparkle/
│
└── Tests/               one directory per piece, mirroring the tree; Support/, the
                         tests' shared helpers; and Consumer/, the minimal consumer
```

### The dependency map

Each piece may import only these, besides `core/Common`, which every piece may use. The map is derived from every quoted and angled include in a Vibe checkout, its `vibe-libs/` submodule included (`scripts/plan/derive-deps.py`). A file here belongs to the piece its directory names. The script once assigned a file still in Vibe to the piece it would move into. Every piece has moved, so its list of Vibe paths is empty, and it now reads only this repo's sources. Its output at Vibe `1ffdba88`, whose submodule holds the tree of this repo's `bc694eb`, is the table below, edge for edge, besides the edges to `core/Common`. There is one exception. It cannot see `system/Updates`' edge to `third_party/Sparkle`, since `<Sparkle/Sparkle.h>` is a framework's header, so that row is kept by hand.

The script resolves an include as the compiler does: a quoted include in its own directory first, then the macOS app's header search paths in its build's order, then a unique basename. Those paths are its templates' from `vibe-libs.yml`, then its own from `project.yml`. **A collision those rules cannot settle fails the script** until an explicit mapping names the header the build uses, so no edge comes from the filesystem's order. TagLib's `<vorbisfile.h>`, for one, is TagLib's own Ogg Vorbis header, which the `taglib/ogg/vorbis` search path finds, not libvorbis's.

The table is the map after the planned cuts. **The template for a piece is written from this map, and `check-pieces.py` fails on any edge missing from it.** Rerun the script after each cut, and update the map in the same change. The script reads `vibe-libs/` too, so an edge into a piece that has moved here stays in its output. Each cut records the script's output and the Vibe commit it ran on. **The script reads includes, not symbols, and it is no list of sources.** So the map also changes when a declaration moves between headers, even when no include goes away.

| Piece | Depends on |
| --- | --- |
| core/Common | nothing |
| core/Graphics | nothing |
| files/FileLoading | audio/AudioTypes |
| files/DiskCache | third_party/PINCache |
| files/HTTP | nothing |
| files/RemoteFiles | files/FileLoading, files/HTTP, audio/Decode |
| files/ShareLinks | files/HTTP |
| files/SandboxAccess | nothing, macOS only |
| audio/AudioTypes | nothing |
| audio/DSP | third_party/r8brain |
| audio/Analysis | audio/AudioTypes |
| audio/Decode | files/FileLoading, third_party/dr_mp3, third_party/dr_flac, third_party/dr_wav, third_party/vorbis |
| audio/Meter | nothing |
| audio/FX | audio/DSP |
| audio/OutputDevices | nothing |
| audio/Player | audio/AudioTypes, audio/DSP, audio/Decode, audio/FX, audio/Meter, audio/OutputDevices, files/FileLoading |
| media/Tags | audio/AudioTypes, third_party/taglib |
| media/Metadata | audio/AudioTypes, audio/Decode, media/Tags, files/DiskCache, files/FileLoading, core/Graphics, third_party/taglib, third_party/PINCache |
| media/PlayQueue | nothing: its entries are opaque objects (seam 19) |
| media/Playlists | audio/AudioTypes |
| media/FolderScan | audio/AudioTypes, files/FileLoading, media/Playlists |
| waveform/Waveform | nothing but Accelerate and Compression |
| waveform/WaveformStyles | waveform/Waveform, core/Graphics |
| waveform/WaveformLoading | waveform/Waveform, audio/AudioTypes, audio/Decode, files/DiskCache, files/FileLoading, third_party/PINCache |
| waveform/WaveformView | waveform/WaveformStyles, waveform/Waveform, ui/Controls, core/Graphics |
| ui/Controls | core/Graphics |
| ui/SettingsWindow | ui/Controls, core/Graphics, macOS only |
| ui/Shortcuts | ui/SettingsWindow, macOS only |
| system/NowPlaying | core/Graphics, media/PlayQueue |
| system/AppOpening | nothing, macOS only |
| system/Updates | third_party/Sparkle, macOS only |
| dev/DebugChannel | nothing |
| dev/iOSDriver | nothing, iOS only |
| tools/strings | nothing: it is scripts |
| third_party/PINCache | third_party/PINOperation |
| third_party/vorbis | third_party/ogg |
| third_party/Sparkle | nothing, macOS only |
| every other third_party piece | nothing |

**Edges in Vibe's tree before the cuts, which the cuts removed**, so none of them is declared:

| Edge before the cuts | Removed by |
| --- | --- |
| every piece → Vibe's app code | the settings, strings, and reach cuts |
| files/FileLoading → audio/Decode | seam 15: the handle protocol, and the read-ahead's test hooks in a header of FileLoading's own |
| files/FileLoading → dev/DebugChannel | cut 1 |
| files/RemoteFiles → media/Playlists | cut 2 |
| files/ShareLinks → Vibe's `LinkStore` | seam 20: `LinkClient` stops importing the store |
| files/ShareLinks → audio/AudioTypes, through `LinkStore.h`'s import of the playable-item protocol | seam 20, the same cut |
| media/Metadata → files/SandboxAccess | cut 4, folder art's providers |
| media/Tags → media/Metadata, media/Tags → files/FileLoading | seam 16, art bytes and a byte-range reader |
| media/FolderScan → media/Metadata | seam 23, the walk's file handler |
| waveform/WaveformLoading → audio/Analysis | seam 17, the decode's observers |

**Planned edges.** The script read the imports of its day, so it could not see an edge a new type would add. Each new type's owner, and what it implies:

| New type | Owned by | Used by | Edge it adds |
| --- | --- | --- | --- |
| the playable-item protocol | audio/AudioTypes | audio/Player, media/Metadata, waveform/WaveformLoading; adopted by the app's entries | none: each user already depends on AudioTypes |
| Metadata's holder protocol | media/Metadata | adopted by the app's entries | none |
| the handle protocol of FileLoading | files/FileLoading | adopted by audio/Decode's file handle | none: Decode already depends on FileLoading |
| a waveform decode's observer | waveform/WaveformLoading | the app, which attaches audio/Analysis | none: the app joins them |
| the playlist record | media/Playlists | media/FolderScan, the app | none: FolderScan already depends on Playlists |
| the catalog scan's verdict and read policy | media/FolderScan | the app | none |
| no type: Now Playing takes the track's source key, title, artist, and image as values | system/NowPlaying | the app | none |
| the settings pane's effects sink: a block over an integer the app interprets | ui/SettingsWindow | the app | none |
| the typography slot table | core/Graphics | ui/Controls, ui/SettingsWindow, the app | none: both already depend on Graphics |

**PlayQueue stays free of all of them.** Its entries are opaque objects, never the playable-item protocol. The queue needs only each entry's identity, so declaring that protocol would add an edge to AudioTypes for nothing.

**Four placements keep the map acyclic and small.** `WaveformZoomMath.h` sits in WaveformStyles, because three renderers import it. `NSURL+Hash`, the disk key, sits in `core/Common`, so FileLoading and ShareLinks need no cache. `AudioTypes` holds the format identifiers, the playable extensions, the CUE window math, and the musical key, so Tags, Playlists, FolderScan, and Metadata need neither Decode nor Analysis for them. The fake web server sits in ShareLinks, because it imitates those services' hosts. Its serving engine sits in HTTP, so HTTP's and RemoteFiles' tests need no ShareLinks.

**A piece whose row says macOS only builds for one platform.** It has no `iOS/` half and no iOS target. An iOS target that lists its template, directly or through another template, fails the check. It may keep its files in a `Mac/` half, so the shared files it gains later move nothing. `ui/Controls` did, until its indicators joined it in Phase 3's step 7. Its mark was lifted then, and it gained an iOS target. The checker reads those words since the shell track's step 2, on 2026-10-20, before the first such piece. **A row that says iOS only is the mirror**: no macOS target lists the piece, so it has no macOS test bundle, and its iOS target is its build. `dev/iOSDriver` is the first, since XCUITest's touches exist only on iOS. The checker reads those words since its move.

**A stack would be a template that lists other templates and compiles nothing.** `vibe-libs.yml` offers none yet. Each piece's template already lists the templates of the pieces it depends on, so an app's `project.yml` names only the pieces it uses. A Playback stack (Player and everything it needs) and a Waveform stack (the four waveform pieces) are the obvious first ones. The checker allows a stack, and fails a template that compiles sources but is no piece's.

**What a few consumers would take:**

| Consumer | Pieces |
| --- | --- |
| A music player | Player, the four waveform pieces, Metadata, PlayQueue |
| A tag editor | Tags, Metadata |
| An app that reads users' iCloud and network files | FileLoading, and nothing from audio |
| A DJ tool reading CUE sheets | Playlists |
| A waveform plugin | Waveform today; WaveformStyles once its later C++ rewrite lands |
| A mac app that plays no audio | SettingsWindow, Shortcuts, Controls, Graphics, Updates, DebugChannel, and tools/strings; OutputDevices and Meter if it meters an output |

### What some pieces mean, in plain words

- **FileLoading** turns a path into bytes you can read. The file may be local, an iCloud placeholder that must download first, a file still downloading, or a file on a slow network share. Every request for one file shares one download and one open, so a playlist scan and the play button never download the same file twice. The file the user is waiting on goes first, and background reads step aside.
- **Player** is everything between a decoded file and the speaker. The voice bus, the master bus, the output unit, and the categories that bind them to a device only work together, so they are one piece.
- **OutputDevices** finds the outputs and describes them: on the mac, devices, rates, and formats; on iOS, the audio session and its routes. It knows nothing about the player.
- **PlayQueue** keeps an order over the caller's own entries. It never copies or compares them by content.
- **WaveformLoading** decodes a file into a waveform and caches it. Decoding without caching has no second user, so the two are one piece.

### Analyzing many files

Vibe decodes a waveform only for the track on screen. An app that analyzes a whole library needs more, and it is new behavior in WaveformLoading, built in Phase 5 as its own change:

- **A scan request kind**, apart from the track on screen. The app admits one at a time.
- **Admission stops while an open the user waits on is active**, read from FileLoading's foreground state. It resumes when the open settles.
- **An active scan decode is cancelled outright, not detached.** Today a superseded load is detached and finishes its decode, which keeps reading the file. A scan decode that yields must stop reading, and its partial summary is dropped, never filed.
- **The playing track's waveform is never cancelled or delayed** by any of this.
- **Tested on a throttled source**, with Vibe's fake cloud and read-ahead stubs, so a slow file proves the decode yields within one block.
- **Tags have a cache-only path.** `loadCachedMetadata:` reads only the cache and never the file. It is the path for a File Provider placeholder, whose bytes cannot be read without downloading it. A remote placeholder can read its tags by range instead.

**Done when** the throttled-source tests pass, and Vibe's waveform benchmarks show no change for the track on screen.

### Scanning a catalog

FolderScan's walk opens the readable part of a folder. `expandAndFilterList:` returns entries and a folder count, with no way to cancel and no verdict on whether it saw everything. Its enumerator logs an error and carries on. That is right for an open. It is not enough for a catalog, which may mark a file missing only after a scan that saw the whole folder. The walk also reads CUE sheets, beside the files and embedded in FLAC, so a listing may read file contents.

Done 2026-10-23: `scanRoots:readPolicy:progress:batch:completion:` is the scan, and Vibe's file-name search is its first caller (this repo's #56, Vibe #405). Two corrections came with it. There are two policies, not three. No walk opens a cloud placeholder FLAC for its sheet, since the read would download it, so no policy reads every file. And the open does not read every file either. It reads each sheet beside the files and the sheet inside a large local FLAC. The local policy reads the same, except a sheet that is a cloud placeholder. A scan reads no placeholder, since background work must not download. The open also stays a caller of the one enumerator, not of the scan's batches. A batch's sheets claim only their own directory's files, while the open's claim the whole walk in its sorted order. Its entries then stay byte-identical. FolderScan's `AGENTS.md` has the rest.

The catalog scan is new behavior in FolderScan. It lands after FolderScan's move, as its own change:

- **Files arrive in bounded batches**, not one array at the end.
- **Every enumeration failure is reported** with its directory.
- **Each root ends with one verdict: complete, partial, or cancelled.** Only a complete verdict lets a catalog mark unseen files missing.
- **A read policy says which contents the scan may read**: none, or what is local. It covers CUE sheets beside the files and embedded in FLAC. Under none, a CUE sheet is reported as a file and not expanded. Under local, so is a sheet that is a cloud placeholder, which an open reads.
- **A token cancels the scan**, checked between entries. A cancelled scan never reports complete.
- **There is one enumerator.** `expandAndFilterList:`, which Vibe's opens call, becomes a caller of the same walk and reads what the local policy reads. Vibe makes its own rows from its entries. So CUE handling never runs under different access rules.

**Done when** tests show these: a partly unreadable tree reports partial, a cancelled scan reports cancelled, a large tree arrives in bounded batches, and a listing over the fake cloud reads no audio. Vibe's open behaves as before.

### Groupings forced by today's code

- **`Player` holds the master bus and the device categories.** The master bus composes the varispeed, the FX, and the meter. The categories read the player's private state.
- **`WaveformStyles` holds the morph engine.** The renderers drive it directly.
- **`waveform/Waveform` holds Vibe's C++ engine, and its Darwin part beside it.** The C++ came from Vibe's `Packages/WaveformCore` with its tests. Its headers sit beside its sources, and its `Package.swift` did not move. `AudioWaveform.h` and `.mm`, with `CodableAudioWaveform`, joined the C++ in the same piece (this repo's #33). The wrapper is more than the cache's entry: both views hold it, the style registry draws from it, and the widget publisher bakes it. With it in WaveformLoading, drawing would depend on Decode and FileLoading.
- **WaveformLoading's decodes do not go through FileLoading's claims.** The loader opens its own handle. So FileLoading's foreground rule, which yields background downloads to the open the user waits on, never stops a waveform decode of a local file. An app that analyzes many files schedules that itself (below).
- **Artwork is inside `Metadata`.** The art is found during the tag parse and cached beside the tags. Nothing uses one without the other.

**Artwork is the one place the engine hands out UI types.** `Metadata` returns `NSImage` or `UIImage`. AppKit and UIKit are always present, so that is tolerable. A UI-free version would return a `CGImage`. Leave it until someone asks.

### The shell pieces

A third app, a mac app that plays no audio, is the second consumer of Vibe's shell: its settings window, its drawn controls, its typography, and its remappable shortcuts. Measured by imports on Vibe's `main` at `7fbeaaba`:

| Piece | From Vibe | Lines | Reaches into Vibe today |
| --- | --- | --- | --- |
| ui/Controls, Mac/ | `SymbolButton`, `VibeDetentSlider`, `ScaledImageView`, `CrossfadingImageView`, `VibeLinkLabel` | 827 | nothing |
| ui/Controls, Mac/ | `DrawnControls`: `VibeSlider` and `VibeSwitch` | 558 | `Formatters.percentString:`, for one accessibility value |
| ui/SettingsWindow | `SettingsFormViews` | 751 | nothing |
| ui/SettingsWindow | `SettingsPaneViewController` | 854 | `MainPlayerController`, held and called once, and the `VibeSettingsLiveEffect` type |
| ui/SettingsWindow | `SettingsSidebarController` | 275 | two strings |
| ui/SettingsWindow | `SettingsWindowController` | 773 | the list of nine panes, 34 strings, and the Themes and Audio panes by name |
| core/Graphics, Mac/ | `Fonts` | 194 | `AppTheme`, for the five font slots and the theme push |
| ui/Shortcuts | `ShortcutRules.h`, `SettingsShortcutsViewController` | 700, at `4fc7b2b6` | nothing since cut 30 (Vibe #361) and the layout's cut (Vibe #366). The keyboard-layout half left Vibe's `MainMenuBuilder` for `ShortcutLayout`, which moved with them. |

**What stays in Vibe:** `AppSettings` and `SettingsRules.h`, which are policy; every pane's content; `ArtworkImageView`; `MainMenuBuilder` without its keyboard-layout half (the shell track's step 6 moved that half); Vibe's command table; the About window; the iOS settings screens; and the theme record, its store, and the Themes pane.

**The theme engine does not move.** `AppTheme` and its categories are about 3,500 lines, and the Themes pane 2,600 more. Its slots are Vibe's product: the waveform, the playlist, the transport buttons, and the window chrome. A theme piece needs a schema-driven record, which is a redesign, not a move, and no second app wants user themes. What is generic in it is small: the dark and light color-pair row, its seeding from the displayed fallback, and copy and paste of a color as hex. Those move into the form views, bound to a read block and a write block instead of a theme base (cut 29). A theme piece is reconsidered only when an app asks for user themes.

**The debug walker splits.** Vibe's `DebugSettingsUI` drives a pane by row title and is keyed on the form-view classes. Its generic half, the walk from a row title to the controls beside it, moves as a debug seam of SettingsWindow, beside the class it opens, as every seam does. Vibe's theme and app verbs stay with the channel's command tables. So DebugChannel keeps depending on nothing.

**The cuts, in Vibe first**, continuing the numbering:

- **24. The pane base takes an effects sink.** `SettingsPaneViewController` holds `MainPlayerController` and calls `applySettingsLiveEffects:` once. It takes a block over an opaque integer instead. Vibe's `VibeSettingsLiveEffect` enum stays in Vibe, and its controller supplies the block.
- **25. The settings window splits.** The generic window keeps the split controller, the sidebar and its search, the history, the size funnel, the pane-title chain, and undo routing to the selected pane. It takes its panes as a list of view controllers and its strings pushed in. A Vibe subclass supplies the nine panes and the Themes toolbar items.
- **26. The drawn slider takes its percent formatter**, one block, so `DrawnControls` reaches nothing.
- **27. Fonts takes its slots from the app.** It keeps the face-and-size table keyed by an integer slot and the monospaced-digits rule. The slot enum, the five Vibe slots, and `applyThemeFonts:` move to Vibe, which pushes faces in.
- **28. The shortcut encoding leaves the command table.** `ShortcutRules.h` splits: the key-code-or-character encoding, the modifier mask, and the matching rules move, and Vibe's commands and their defaults stay. The recorder pane takes rows from the app, each a pair of identifier and label.
- **29. The color-pair row moves into the form views**, bound by blocks, as above.
- **30. The Shortcuts pane takes its rows, strings, and store blocks** (Vibe #361).

**Done when** this returns nothing in Vibe:

```
grep -rln 'AppSettings\|AppTheme\|VibeStrings.h\|MainPlayerController\|MenuValidationRules\|MainMenuBuilder\|MenuShortcutRules\|Formatters' \
  Vibe/Mac/Menu/ShortcutRules.h Vibe/Mac/Menu/ShortcutLayout.* Vibe/Mac/Settings/SettingsShortcutsViewController.*
```

It returned nothing on Vibe's branch after cut 30 and the layout's own cut, before the move. Every shell file it names now lives here. The drawn controls and the symbol button are in `ui/Controls/Mac/`. `Fonts` is in `core/Graphics/Mac/`. The form views, the pane base, the sidebar, and the generic window are in `ui/SettingsWindow/Mac/`. The shortcut encoding, the layout, and the Shortcuts pane are in `ui/Shortcuts/Mac/`.

## How an app uses a piece

**A git submodule, compiled in tree.**

- The app's repo has this repo as a submodule at `vibe-libs/`, pinned to a commit. Vibe's `make project` runs `git submodule update --init --recursive` before it generates when the submodule is not checked out, so a fresh clone or a worktree works. It never moves a checkout already there. It says when that checkout is not the pinned commit.
- The app's `project.yml` has `include: [vibe-libs/vibe-libs.yml]`. Each app target lists the pieces it wants under `templates:`. It sets `templateAttributes: {excludedPlatform: iOS}` on macOS, or `Mac` on iOS.
- The pieces' files compile as the app's own sources. Each vendored library keeps its own compiler flags in its template.
- The pieces read two preprocessor switches, verbose logging (`VIBE_VERBOSE_LOGGING`) and the signposts (`VIBE_SIGNPOSTS`). Vibe maps the first from its beta switch and sets the second in its Debug configuration. A test target here turns on the ones its tests need.
- The log subsystem is the main bundle's identifier, so each app logs under its own name.
- Two apps on one Mac coexist. A piece's queue labels and error domains start `vibe-libs.<piece>` and name no app. The one exception is HTTP's kept-part xattr, which parts already on disk carry. The debug channel takes its name from the app when the app installs it, so one app's commands never reach another's. The cleanup landed on 2026-10-25.

### Why compile in, and not link

The constraint is no performance change in either app. Compiling in adds no boundary, since the same files build with the same flags. That makes a change unlikely, not impossible. A flag, a macro, or a changed call path can still move cost. The logging change showed it: a stderr hook inside the log check cost 2 to 3% on scans that never log. **So the claim is measured equivalence, proven for each move**, not a guarantee from the shape alone.

| Shape | Run time | What it costs |
| --- | --- | --- |
| Templates, compiled in | the same files and flags as today | nothing |
| Static library targets in the shared spec | identical, given `-ObjC` on every app | A library is built once per project. Vibe's audio tests build four render files at `-O2` and turn verbose logging on, and its unit tests link a stand-in metadata class. One shared build cannot serve both. |
| A Swift package, linked | slower in Debug | Xcode builds a package with its own settings, unoptimized in Debug. `-O3` for the decoders exists only as `unsafeFlags`, which a package pinned by version may not use. There is no prefix header and no per-file flag. |

Vibe has no link-time optimization today, so files inline across each other only through headers. A library boundary would not change that. The difference is entirely in the flags and the test builds. The number of pieces does not matter either.

**The proof, for the pilot and every move**, run in Vibe with its `vibe-perf` skill:

1. Fix the before and after commits, and name both in the pull request.
2. Measure each affected benchmark's own no-change band: the before commit against itself. A benchmark that swings with binary layout, as the metadata scans do, gets its band from builds that change only layout.
3. `perf.py compare <before> <after>` keeps each benchmark inside its own band. The pull request reports every outlier and every rerun, not only the median. Similar totals inside a tolerance are context, not proof that each moved workload stayed the same.
4. `make test-audio` wall time before and after stays within noise. This catches a lost Debug optimization, which Release benchmarks would not show.

Vibe's audio, render, and signal-quality suites keep running against the moved code at every step. They are the gate that the extraction changed no behavior.

**The build audit, before a move deletes Vibe's source entries.** The pilot moved one plain source pair. Later pieces bring C++, platform categories, framework links, resources, third-party include collisions, and flags per configuration. So each move compares what every affected target compiles, before and after:

- The compile inputs and their flags, for the macOS app in Debug, Release, and AppStore, the iOS app, the widget extension, the host-less tests, the render tests, the waveform engine's tests, and the benchmark tool `perf.py` generates.
- A file the move promises unchanged is compared byte for byte.
- The source list changes only by the moved files' paths.
- Every affected target builds and passes, the x86_64 slice included. No Intel benchmarks are added.
- The widget extension compiles no engine code, but the iOS app's widget publisher draws with the waveform wrapper and renderers. So after the waveform moves, the app must publish the same widget images.
- `perf.py` still builds old refs, whose waveform engine sits at Vibe's `Packages/WaveformCore`. So its check for the engine's headers searches there and in `vibe-libs/`.

Preparing sources and changing behavior get separate evidence.

### When to switch shapes

- **To static library targets**, when the test targets no longer compile production sources and two consumer targets in one project make the double compile cost real time. The template becomes `type: library.static`, apps change `templates:` to `dependencies:`, and every app and test target gets `OTHER_LDFLAGS: -ObjC`. **TRAP: without `-ObjC`, a static library silently drops category-only objects**, such as the cache-key category and every debug seam.
- **To a Swift package**, only for outside users. Measure the decoders without `-O3` first. Add whole-file `#if TARGET_OS_OSX` guards to the platform halves, since a package compiles every file on every platform. Keep C++ out of public headers. Tag `0.x` until the API settles. The waveform engine's `Package.swift` did not move with the engine, so a package for it starts here.

## The boundary check

This repo's `project.yml` has one test bundle per piece. Each sets `USE_HEADERMAP: NO`, `ALWAYS_SEARCH_USER_PATHS: NO`, and `GCC_PREFIX_HEADER: ""`, with header search paths for only its piece and the pieces it declares. An import outside them fails to compile here. Each piece also builds for iOS, so an AppKit leak fails here too, unless its map row says macOS only.

**A compile alone cannot enforce every edge.** One build with the headermap off sees every header its templates expose, so an include of a piece two steps away compiles. A header nothing compiles is never checked at all. So `scripts/checks/check-pieces.py` resolves every include itself. It reads the spec through `xcodegen dump`, as XcodeGen does, and checks:

- every piece has an `AGENTS.md`, a row in the map, a template, a macOS test bundle over its tests, and an iOS target. A `tools/` piece is scripts, so it has only the `AGENTS.md` and the row. The checker reads the words macOS only at the end of a map row: such a piece has no iOS target, no iOS target lists its template, directly or through another template, it has no `iOS/` directory, its template need not exclude one, and its files import AppKit with no platform guard. It reads iOS only the same way, as the mirror: no macOS target lists the piece's template, so it has no macOS test bundle, it has no `Mac/` directory, and its files import UIKit with no platform guard.
- the map names only known pieces and has no cycle, counting every piece's edge to `core/Common`
- each template compiles and searches only inside its piece, excludes the other platform's half, and lists only the templates the map allows. A vendored piece's template may also search `third_party/` itself, since apps spell its headers with the library's directory, as `<ogg/ogg.h>`. A vendored piece has no platform halves.
- every include, quoted or angled, resolves as the compiler would: a quoted one in its own directory first, then every piece's search paths, then a unique basename, as an app's headermap would. An include that reaches two pieces fails. The checker's `SETTLED` table is the one exception: it names the header an app's build must find, for a spelling two vendored pieces answer. An include of a piece the map does not allow fails. A test may also include a piece its test bundle lists, so a test can check its piece against another's data. A test may include a helper from another piece's tests only through a path its test bundle searches, and only from a piece it may include, as RemoteFiles' tests take HTTP's `HTTPStub`. A quoted include that reaches no piece fails, since an isolated build cannot find it.
- no two first-party headers share a basename, since an app's headermap would pick one
- every header is compiled by a source or test of its piece. A header-only piece imports its headers from a plain probe file in its tests, which its iOS target compiles too.
- `Mac/` and `iOS/` are the only platform directories, and only at the top of a piece, where the template's exclude reaches them. A shared file imports AppKit or UIKit only under a platform guard. A half never imports the other platform's framework.
- every target that builds a first-party piece, directly or through another template, sets `excludedPlatform` in its `templateAttributes`: `Mac` on iOS, `iOS` on macOS. Without it, the template's exclude names nothing, and both halves compile.
- no `#if DEBUG` in a shipping header
- the other app's name appears nowhere
- no file outside `third_party/` holds a merge conflict marker. A marker is seven `<`, `=`, or `>` at a line's start, then a space or the line's end. A longer underline of `=` is not one.
- no `.md` file outside `third_party/` has a line over 1,500 characters, Vibe's own limit
- the sources of `system/Updates` that reach Sparkle are `VibeUpdater.m` alone, since an app's configuration with no updater excludes it by name
- and it lists the classes with no prefix

**The checker has tests of its own.** `scripts/checks/check-pieces-test.py` copies the repo, breaks one rule per case, and fails unless the checker fails with that rule's message. Each new rule gets a case. Two cases are the ones a review reproduced against the first checker: an angled include of another piece from `core/Common`, and a map edge from `core/Common` back to a piece that uses it.

**A minimal consumer builds like an app.** `Tests/Consumer/` is a project of its own. It includes `vibe-libs.yml` from two directories up, sets `VIBE_LIBS_ROOT`, lists the templates it uses, builds with no prefix header and no headermap, and runs. It is the consumer the end of Phase 3 asks for. Its row, `ConsumerTrack`, adopts the playable-item protocol and Metadata's holder protocol, with a source key and a CUE window. A queue of these rows plays through a player on the manual render pump: two rows of one file, then a CUE window of another. Its delegate parks the queue's successor, as an app's does. The first track's end advances to the second row, and the window plays only its own frames. Every frame comes back exactly. It cancels an open over the fake cloud while the download is in flight, and the claim and the transfer let go. It roots a metadata cache and a waveform cache in temporary directories, and the second load from each is a hit. It needs no audio device. Each check sits in a file named for its piece, or in `main.m`, which runs them all.

CI runs `make check-pieces`, `make test-strings`, `make test`, `make build-ios`, and `make consumer`. `make analyze` ran clang's static analyzer over every piece's macOS test bundle from 2026-10-21 to 2026-10-30. It was removed. Every finding in that time was in a test or a test fake, none in code an app runs. It was CI's costliest job, and Vibe's own analyzer already reaches the pieces Vibe compiles. GitHub Actions is free for a public repo, macOS runners included.

## The work, in order

**Correct the boundaries, prove the smallest extraction, move the first path, let the other app build on it, then grow from actual reuse.** Each move is a pull request here, plus one in Vibe that bumps the submodule and deletes what moved. Each piece's `AGENTS.md` moves with it.

**Every change across the repos lands in one order:** the commit here first, then the consumer's pin, then the consumer's gates. The old pin is the rollback. Each move reports the code it removed from Vibe apart from the code it added across both repos, since a relocation is not a net reduction. A plan sentence in a move's pull request names only this repo's pull request, because naming Vibe's forces a re-pin after Vibe's pull request exists. A mover adds no remote to a vibe-libs worktree, since that writes the shared repository config, and fetches from a path instead.

**A move carries its history with `git filter-repo`**, run on a fresh clone of Vibe and keeping only the moved paths. It arrives here as one merge with `--allow-unrelated-histories`. The filter's message callback is `scripts/plan/filter-messages.py`, whose header gives the command, and `make check-pieces` runs its test. It rewrites each commit's message. It strips the trailers, so no tool's credit arrives. **It also neutralizes GitHub's closing keywords before `#<number>` and `GH-<number>`.** Those are close, fix, and resolve, in every tense and any case. It rewrites `Closes #45` as `Closes Vibe #45`, and `Closes GH-45` as `Closes Vibe GH-45`. Neither closes anything. A Vibe commit's number names Vibe's issue, but GitHub reads it here as this repo's. A Vibe commit's `Closes #45` once closed this repo's #45 when its move merged. **Each merge to main is followed by a check that no pull request was closed without a merge.** `gh pr list --state closed --json number,title,mergedAt` lists them, and one with no `mergedAt` was closed unmerged.

**A piece's tests are written against its own types and fixtures before the move.** A test that holds an app's model or reads an app's fixtures cannot build here. So a prep commit in Vibe rewrites it first, under Vibe's gates, and the move then carries it unchanged. The PlayQueue and Playlists move needed two: the queue's tests moved onto a row of their own, and the readers' tests onto entries. A test of the app's own type stays in the app.

### Phase 0: setup and experiments

**The license is Apache 2.0** (decided 2026-10-18), Vibe's own, so code moves between the repos under the terms it already has.

The eight build questions, answered on 2026-10-18 with XcodeGen 2.46.0, Xcode 27.1 and Swift 6.4, in throwaway projects:

| # | Question | Answer |
| --- | --- | --- |
| 1 | Do paths in an included spec resolve relative to that spec? | **Yes.** A template's `core/Common` became `vibe-libs/core/Common` in the app's project. The submodule can sit anywhere. |
| 2 | Can a template list other templates, and does `${excludedPlatform}` substitute? | **Yes, both.** A piece's template pulled in Common's through its own `templates:`. The `Mac/` half compiled and the `iOS/` half did not. A per-file `-O3` carried through. |
| 3 | Do a template's header search paths join the target's? | **Yes, if the target sets its paths in its own `base`.** Two templates' paths and the app's own all reached the target. **But a value the target takes from a settings group is replaced, not joined.** Vibe's pilot found it: its app targets took TagLib's and WaveformCore's paths from a group, and the template dropped them. Vibe now sets them in each app target's base. |
| 4 | Does a headermap-off build fail on a stray app import? | **Yes**, with `'AppOnly.h' file not found`, while the app's own build of the same file passes. |
| 5 | Does `xcodegen dump` keep an included spec's templates? | **Yes, and better than hoped.** The dump rewrites their paths relative to the app, and a project regenerated from the dump elsewhere has the same file references. So `perf.py`'s rebuild from the dump works unchanged. |
| 6 | Does the pilot pass the performance proof? | **Yes.** Across all 619 component benchmarks, 539 sit within ±0.5% of retired instructions, against 538 with no change at all. Every `pitch.*` benchmark is unchanged to 0.0%. The few that moved fell back into the noise when rerun with 6 rounds (Vibe #315). |
| 7 | When does SwiftPM refuse `unsafeFlags`? | **Only from a dependency pinned by version.** By path, by branch, or by revision, it accepts them. A version-pinned consumer fails with "contains unsafe build flags". This matters only for a future `Package.swift`. |
| 8 | Does `submodules: recursive` reach every CI job in Vibe? | **Yes.** Every job on Vibe #315 passed with the submodule checked out: the Linux checks, which now fail without it, and the macOS, iOS, unit and audio jobs. |

### Phase 1: the pilot, DSP with the varispeed

The smallest real piece goes first, after its one prerequisite. `AudioVarispeed` uses Vibe's realtime-check macros, so cut 12 first moves the macros out of Vibe's prefix header into `VibeMacros.h`. **Only the realtime brackets move in cut 12.** Vibe's log and signpost macros carry debug-only parts, and a shipping header may not hold `#if DEBUG`. They move when the first piece that logs moves, with a design for those parts. **The pilot then moves that header here with the varispeed**, as the first file of `core/Common`. A header left in Vibe would not satisfy this repo's isolated build. Vibe's prefix header imports it from the submodule. Nothing else blocks the pilot.

`AudioVarispeed` is Vibe's own windowed-sinc converter for the pitch fader. Its distortion sits near −150 dB, against −83 to −135 dB for Apple's Varispeed unit. It is flat to 20 kHz and a bit-perfect pass-through at zero pitch. It costs about 0.2% of one core at 48 kHz. Its API is plain C, it has one caller in Vibe, and its tests and benchmark stand alone.

The pilot proves every step the later moves will take: `git filter-repo`, the template, this repo's CI, the submodule in Vibe, `make project`, worktrees, Vibe's CI checkout, and `perf.py`. **Done when** Vibe's checks pass with the varispeed coming from here, the `pitch` benchmark shows no change, and this repo's CI runs `AudioVarispeedTests`.

### Phase 2: the cuts in Vibe, for the first path

Small pull requests in Vibe remove every reach from the path's code into Vibe's own. Only the cuts the path needs come now. The rest wait for the piece they serve.

**Settings, strings, and app reaches:**

- **1.** A debug seam stops importing the debug channel's parser.
- **3.** The metadata cache takes a root path, as the waveform cache already does.
- **4.** Folder art stops reading the settings and the mac's folder grants. The app installs both as providers.
- **6.** One header in Vibe turns every error code and style identifier into its localized text. The engine reports codes only.
- **7.** File-info and accessibility formatting move out of the metadata record and the views.
- **8.** The waveform style and theme identifiers move from Vibe's settings into the registry and the theme.
- **9.** The mapping from Vibe's settings onto a waveform theme becomes a category in Vibe.
- **10.** The app pushes the mac waveform view its settings, instead of the view reading them.
- **11.** The app pushes the iOS scrubber its settings, instead of the view reading them.
- **12.** The macros move to `VibeMacros.h`. This one lands before Phase 1.

**The seams between pieces:**

- **13. The playable-item protocol.** A small protocol gives an item's file, frame window, source key, and disk key. Only the pieces that read a file take it: the player, Metadata, and WaveformLoading. Vibe's `AudioTrack` adopts it and stays in Vibe, moving to `Vibe/Playlist/` as the row it is, with its tags, analyzed tempo and key, display names, and the rule that tags beat analysis. They take `id` of the protocol and hand back the same object. The queue takes any object (seam 19). The CUE window math goes to AudioTypes, so Playlists and FolderScan need no Decode for it. The seam landed on 2026-10-21 (Vibe #351).
- **14. `AudioFileOpenRules.h` splits.** It held four parts, and four areas imported all of them. Each part went to the piece that owns it. The open's delivery states sit beside FileLoading's open token. The path spelling joined `FilePaths`, which goes to `core/Common`. The network mount's read-ahead rules and math sit beside FileLoading's read-ahead. The tail window went beside RemoteFiles' placeholder store, in `TailWindowMath.h`. That header later joined Decode, since it states what Decode's opens read, and RemoteFiles depends on Decode for it. The seam landed on 2026-10-21 (Vibe #353).
- **15. The file loader stops naming the audio file handle.** Its opener is already a block. The handle it serves becomes a small protocol, `ServedFileHandle`, that only holds a stream. Interrupting a wait stays with the opener's `interrupted` block. It no longer calls into `AudioTrack` to forget memoized cache keys. It bumps the generation on `NSURL (Hash)` instead. A memo stamped below it is stale (Vibe #351).

  **The read-ahead's test hooks move too.** `NetworkReadAhead.m` imports `AudioFileHandle+Debug.h` in Debug, and that header imports the concrete handle. So a FileLoading build in Debug would still need Decode, which already needs FileLoading. The hooks' declarations go to a debug header of FileLoading's own. Decode's category forwards to them, so its read-ahead tests keep the same hooks. **Done when** FileLoading builds and tests alone in Debug, with no Decode header path. A scan of every debug seam in Vibe found no other header that declares hooks for two owners. The seam landed on 2026-10-21 (Vibe #353). Its done-when was met when FileLoading moved (this repo's #18).
- **16. Tags returns art bytes and takes a byte-range reader.** Before it, the TagLib wrapper returned an artwork extractor and read remote ranges through the materializer. The seam landed on 2026-10-21 (Vibe #358).
- **17. The waveform decode takes observers of each mono block.** Before it, the decode built the tempo and key analyzers itself, and the cache knew what they compute. It checks that a saved entry covers the tempo, key, and bands a request asks for. It files the analysis with the summary and hands it back on a hit. A request for the same source can join a running decode. A cancelled request detaches its decode, which finishes for the cache. The observer contract keeps all of that, in the fewest values and blocks:
  - **An observer has a stable identifier**, which names its result in the archive. Vibe's two are the tempo and the key.
  - **A request lists the observers it wants.** When a decode starts, the loader asks each for a sink, given the sample rate and the frame window. The sink takes each mono block in order.
  - **When the decode finishes, each sink returns one result, which may be any property-list object.** The cache files it beside the summary, under the observer's identifier.
  - **A cache hit decodes nothing.** The cache hands back the filed results with the summary, so the app still gets its tempo and key.
  - **An entry covers a request only if it holds a result for every observer listed.** A request that asks for more decodes again.
  - **A request joins a running decode only if that decode carries every observer it wants.** Otherwise it starts its own.
  - **A cancelled request detaches its decode, as today.** Its sinks still finish, so the filed entry is whole. Cancelling outright belongs to the scan work, in its own change.
  - **A late completion reaches only a request that is still current**, by source key and version (rule 4).
  - **A CUE window decodes only its frames**, so its observers see only those.

  The analyzer classes stay out of WaveformLoading. The bands stay the loader's own, since the summary holds them. The archive's format changed with this seam, as decided on 2026-10-21 (Vibe #355). Each entry now lists its results under their identifiers, so a reader needs no list of names. A result is any property-list object, so an app can file a beat grid or a loudness curve. **Done when** tests cover a decode, a cache hit, a missing result, a joined decode, a cancellation, a late completion, and a CUE window. `VibeBenchComponents --analyze` must prove tempo and key identical, and a cache hit must decode nothing. The seam landed on 2026-10-21 (Vibe #355).
- **19. The play queue holds opaque entries.** It keeps object identity, as `VibePlaylist` does today, so two entries for one file stay two entries. A scan of every `AudioTrack` member `VibePlaylist.m` calls finds three, and no others:
  - **The URL**, to index the rows of each file, and **the source key**, to stamp a tempo or key onto every row sounding one window. The app passes both as key blocks when it makes the queue. Vibe passes the URL and the source key. A queue made without key blocks has no lookup by file, stamps nothing, and replaces nothing by file (Vibe #357).
  - **`replacementAtURL:`**, which mints the row that replaces another when a file is converted. The queue stops minting rows. Replacing one row takes the replacement object, already made by the app, which must be fresh, never one already in the queue. Replacing every row of a file takes a block that maps each outgoing entry to its replacement, since each row may be a different CUE window. Vibe makes each replacement with `replacementAtURL:`. The queue keeps what it owns: the indexes, both shuffle orders, and one observer event per replaced row.

  So the queue imports no protocol and no app API, and depends on nothing. Beside Foundation, `RepeatMode.h` is its only import. That header is the whole edge from NowPlaying to PlayQueue. It moved with the queue, and Vibe's settings kept the modes' stored identifiers. The queue half landed on 2026-10-21 (Vibe #357).
- **22. Metadata installs results through a holder protocol of its own.** The loader read an item's installed metadata, installed a result only if none was installed, and delivered only while that result was still installed. It did this through `AudioTrack (Internal)`'s `installMetadataIfUnresolved:` and `deliverIfMetadataStillInstalled:usingBlock:`. That header is gone. Metadata now declares those three operations as its own protocol, `AudioTrackMetadataHolder`. Vibe's row adopts it with the methods it had. Since Vibe #367, it installs a result only if none from the same version is installed. The check and the install stay atomic in the object that holds the result, so a replaced item never shows a stale result. None of it goes into the playable-item protocol, which stays free of metadata. The seam landed on 2026-10-21 (Vibe #358).

- **18. Playlists returns records.** Before it, the CUE and M3U readers returned `AudioTrack` rows. They now return plain records, and Vibe makes its rows from them. The seam landed on 2026-10-21 (Vibe #359).
- **23. FolderScan reports each walked file to a handler.** Before it, the walk noted cover-art candidates itself, through Metadata's `FolderArtRules.h`. The app installs the handler at launch, beside the walk's other handlers. Metadata cannot install it, since it has no edge to FolderScan. The handler returns a rank for each filename. The walk keeps the best-ranked file of each directory. The seam landed on 2026-10-21 (Vibe #359).
- **21. A shell piece reads no app setting, string, theme, or model.** The app pushes values, blocks, or protocol objects into it, when it makes the piece or when one changes. Each piece took its part with its move. DebugChannel's reply to the transport verbs moved to the app's verbs, and iOSDriver reads the app it drives, a relaunch's arguments, and the pinched view from its environment (Vibe #393). Updates became `VibeUpdater`, one class the app makes, feeds its feed override and beta switch, and starts (Vibe #395). SandboxAccess takes the grant panel's text, and the defaults and the key its grants are stored under (Vibe #396). AppOpening hands back the app's rows as an untyped array, and its argument scan takes the options whose values it skips (Vibe #397). The pitch panel takes its title, the fader's VoiceOver label, one formatter for its readout and the fader's spoken value, and its corner radius (this repo's #51, Vibe #399). The seam landed on 2026-10-23.

  Four reaches of app policy were still inside pieces, and they left on 2026-10-25. The player read the app's `--silent` and `--no-audio-hw` in a debug build. The app now sets its seam's two output flags before it makes a player. NowPlaying read `--no-audio-hw` and `--no-now-playing`, and an app's test launch now makes no controller. SandboxAccess treated ~/Music as granted, and the app now names the folders its entitlements grant. `PlaybackDeliveryRules.h` carried three rules of the app's shells, which moved to the app. So no piece reads a launch flag, and the player's header holds only what the player decides.

**No seam waits for its piece.** The Now Playing half of seam 19 came with NowPlaying (this repo's #41). The parts of seam 21 came with wave 10's moves and the pitch fader's (Phase 6). Cut 5 is not planned, since `AudioTrack` stays in Vibe.

**Cut 2 and seam 20 landed with RemoteFiles and ShareLinks on 2026-10-23** (this repo's #46, Vibe #394). Cut 2: the store's budget walk skipped playlist files through Playlists' `isPlaylistExtension:`. The walk, `downloadsUnder:`, became a hook. Its default counts every regular file that is no placeholder. Vibe's Dropbox mirror, the one store that keeps playlists whole, drops them in its override. So RemoteFiles needs neither Playlists nor AudioTypes, and the map gains no edge. Seam 20: `LinkClient` imported `LinkStore.h` only for the link error's domain and constructor. Both moved beside the client. `LinkStore.h`'s import of the playable-item protocol stays in Vibe with the store, so ShareLinks reaches no AudioTypes.

**Before Phase 3 started**, every item it waited on was met or recorded. The checker covered every rule it promises, with a failing case for each (this repo's #3). The contracts of seams 13, 15, 17, and 22, and rule 4's version check, were each traced to tests on Vibe's proofs page, `docs/future/vibe-libs-contract-proofs.md`. That page lists the tests for each line of each contract. Five of its lines have no test that pins them. Three are behaviors: a download of the placeholder's own version leaving the memos alone, a sink's result that is no property-list object, and a file sounding through a re-key. Two are splits held only at compile time: which pieces take the playable-item protocol, and the holder protocol apart from it.

**Done when** this returns nothing in Vibe for the path's directories that remain there:

```
grep -rlF --exclude='*.md' -e AppSettings -e AppTheme -e VibeStrings.h -e FolderAccessManager -e DebugWireFormat -e AudioTrack.h \
  Vibe/Audio Vibe/WaveformUI Vibe/Controls
```

The grep once listed the loading claim and transfer code, the placeholder files, the queue, the playlist files, and the folder walk too. Each has moved here.

### The shell track, beside Phase 2

The shell pieces touch none of the first path's files, so they move while Phase 2 cuts the path. They also prove the toolbox on a macOS-only piece with no audio, which is where the platform rule first bites. In this order, each its own move, each with the proof above:

1. The prefix rename, on the pilot's branches before they merge (Decided).
2. The macOS-only rule in the checker and `project.yml`, with its failing cases. Done 2026-10-20: the checker reads the map's words, `project.yml` states the pattern a macOS-only piece's targets follow, and the checker's tests gain four failing cases and one passing one (this repo's #5).
3. `core/Graphics`, whole, after cut 27. Phase 3's step 2 then moves `core/Common` alone. Done 2026-10-21: its 21 files moved with their history (this repo's #6), their tests run here, and Vibe compiles them through the template (Vibe #350).
4. `ui/Controls`' Mac/ half: the clean five, then `DrawnControls` after cut 26. `VibeLinkLabel` comes from Vibe's About window. Done 2026-10-21: its 12 files moved with their history (this repo's #9), their tests run here, and Vibe compiles them through the template (Vibe #354).
5. `ui/SettingsWindow` after cuts 24, 25, and 29, with the walker's seam and the form views' tests. Done 2026-10-21: its 13 files moved with their history (this repo's #11), and Vibe compiles them through the template (Vibe #356). Two of them came from Vibe's `Util/`, which the done-when grep does not search: `WindowAnimation.h` joined `ui/Controls`, since Vibe's player window reads it too, and `NSString+FormLabel` joined `core/Common`, since Vibe's iOS settings use it too. Vibe had no tests of these files, so their tests are new here.
6. `ui/Shortcuts` after cuts 28 and 30. Done 2026-10-21: its 5 files moved with their history (this repo's #17), and Vibe compiles them through the template (Vibe #366). One more cut came first: the keyboard layout left Vibe's menu builder for `ShortcutLayout`, C functions beside `ShortcutRules.h`. The app pushes the four key names it localizes. The row stayed a pair of identifier and label, not a type. The pane reads only those two, and the command table beside it is pairs too. The default left the row, since the pane never read it. The encoding tests moved, and the layout's and the pane's tests are new here.

**Done when** the minimal consumer opens a settings window of two panes with a color-pair row, a switch, and a slider, records a shortcut, and draws every control, with no string, setting, or type of Vibe's. Vibe's settings window, pitch panel, and About window are unchanged on screen. The drawn-control, symbol-button, and shortcut-rule tests pass from their new homes. **Met on 2026-10-21** (this repo's #17, Vibe #366). The consumer's settings window has three panes, and the third is the Shortcuts pane over two commands of its own. It records ⌃⌥ and a key from a key event sent through `NSApp`, and checks the store and the row it draws. The consumer also draws each mac control into a bitmap with no window, and fails if one draws nothing. Vibe's settings window and its menus are unchanged on screen and in the debug channel.

### Phase 3: move the playback and waveform path

In this order, each its own move:

1. `third_party/`, except Sparkle, which moved with Updates in Phase 6. Vibe's binary is unchanged after. The third-party notices split. Done 2026-10-21: nine libraries moved with their history (this repo's #14), and Vibe compiles them through their templates (Vibe #364). Vibe's objects differ only in two `__FILE__` paths and the build's commit. Each library's notice now sits here, and Vibe's notices keep a row for each.
2. `core/Common` alone, since `core/Graphics` moved on the shell track. Done 2026-10-21: its 24 files and Vibe's script moved with their history (this repo's #13), their tests run here, and Vibe compiles them through DSP's template (Vibe #363). The signposts and the work tally compile under the app's `VIBE_SIGNPOSTS`, since no header here may read `DEBUG`. The tree had named load timing here. It is the waveform decode's, so it stays in Vibe until WaveformLoading moves.
3. `audio/AudioTypes`. Done 2026-10-21: its 7 files moved with their history (this repo's #16), their tests run here, and Vibe compiles them through the template (Vibe #368). It depends on nothing, not even `core/Common`, since nothing in it logs. The player's error codes and `PlaybackIntent.h` stay with the player, since no other piece uses them.
4. `files/FileLoading` and `files/DiskCache`. Done 2026-10-21: FileLoading's 45 files and DiskCache's 2 moved with their history (this repo's #18), and Vibe compiles them through their templates (Vibe #369). FileLoading's five seams, the read-ahead's hooks, and the fake cloud moved with it. Its tests build with no Decode header path, which was seam 15's done-when. They open a fake served handle. Vibe keeps the three that check its real handle is delivered. FileLoading depends on AudioTypes for the extensions whose tags read by range.
5. The rest of `audio/`: DSP, Analysis, Decode, Meter, FX, OutputDevices, Player. Wave 6 moved all but Player on 2026-10-21 (this repo's #20 to #23, Vibe #371 to #374). Player moved on 2026-10-22 (this repo's #29, Vibe #381).
   - OutputDevices: its 16 files moved with their history (this repo's #21), their tests run here, and Vibe compiles them through the template (Vibe #371). It depends only on `core/Common`. The player's device, bit-perfect, and recovery categories stay in Vibe until Player moves, since they read the player's private state.
   - FX and Meter: FX's 5 files and Meter's 11 moved with their history (this repo's #20), and Vibe compiles them through their templates (Vibe #372). Their seams moved with them. The fades joined DSP, since FX's gates and Vibe's player both step them. The FX math and the band math went with their only users, not to DSP, so Meter depends on nothing. The chain's render tests stay in Vibe until the player and its manual render pump move.
   - Decode: the file handle's 7 files moved with their history (this repo's #22), their tests run here, and Vibe compiles them through the template (Vibe #373). The resampler joined DSP in the same move, since the map gives DSP the edge to r8brain. Its quality tests drive Vibe's voice bus, so they stay with the player. The handle's tests write their own fixtures. Vibe keeps its corpus conformance test, since only its audio-quality skill downloads the corpora.
   - Analysis: its 5 files moved with their history (this repo's #23), their tests run here, and Vibe compiles them through the template (Vibe #374). The stream framer stayed with the analyzers, its only users, so Analysis depends only on AudioTypes. `VibeBenchComponents --analyze` found every tempo and key identical over GiantSteps. Vibe's binding of the analyzers to its waveform decode stays in Vibe.
   - Player: its 39 files moved with their history (this repo's #29, Vibe #381), its tests that write their own fixtures run here, and Vibe compiles them through the template. Its `Mac/` half binds a device and drives bit-perfect output, and its `iOS/` half recovers the route. The seam and the manual render pump moved beside their class (rule 8). **The app pushes the player's error domain, as decided**: `VibeAudioErrorSetDomain` once at launch, read through `VibeAudioErrorDomain()`, which asserts in a debug build when nothing was pushed. `AudioError.m` no longer names Vibe's bundle identifier. `AudioErrorRules.h` is shell policy and stays in Vibe, reading the same getter. The render suite moved too, as `Tests/audio/Player/Render`. It plays an app's generated fixtures, so Vibe's audio suite compiles it from the submodule, as it does Decode's fuzz tests. The resampler's quality tests and the FX chain's render test run here. The player was the only caller of three things in other pieces, so they joined it: DSP's three crossfade decisions, and OutputDevices' bit-perfect report with its fold and the saved-device bind.

   **Done when** `VibeBenchComponents --analyze` proves tempo and key exact, and the render suites pass. Done 2026-10-22: Analysis, Decode, Meter, FX, OutputDevices, and Player moved in five pairs (this repo's #20 to #23 and #29, Vibe #371 to #374 and #381). DSP gained the fades in this repo's #20 and the resampler in #22. `VibeBenchComponents --analyze` found every tempo over 655 GiantSteps files and every key over 602 identical across Analysis' move (Vibe #374). The render suites are this repo's `Tests/audio/Player/Render` since Player's move, and an app's test target runs them. Vibe's audio suite runs them. It passed at each of the five moves, with only its corpus test skipped. Two MPEG opens read about 2% up at Player's move, with no moved code on their path. Vibe #381 reports that shift and does not explain it.
6. `media/Tags`, `media/Metadata`, `media/PlayQueue`, `media/Playlists`, and `media/FolderScan`.
   - Tags: the TagLib wrapper's 2 files moved with their history (this repo's #28, Vibe #378), its tests run here, and Vibe compiles it through the template. Its detection tests now write their own files, since Vibe's tag fixtures write WAV and AIFF through Decode's handle. The metadata parse still reads TagLib's own types from the wrapper's file, as the map allows. Phase 4 kept those reads in the parse.
   - Metadata: its 42 files moved with their history (this repo's #35, Vibe #384), their tests run here, and Vibe compiles them through the template. The cache's and the loader's seams moved beside their classes (rule 8). `NSString+CPPStrings` came with the parse, its one user. Folder art's switch and access check were already providers (cut 4), so nothing in it reads an app's settings or grants. The loader tests run over a holder of their own, `VibeLoaderTestTrack`. The tag and fuzz tests write their own files, but Ogg's audio is an app's generated fixtures, so Vibe's audio suite compiles them from the submodule too, as it does Decode's fuzz tests. The parse still reads TagLib's own types, as the map allows.
   - PlayQueue: its 3 files moved with their history (this repo's #30, Vibe #379), their tests run here, and Vibe compiles them through the template. `RepeatMode.h` came with the queue, and Vibe's settings kept the modes' stored identifiers. It depends on nothing. Its tests run over rows of their own, since the queue reads an entry only through its key blocks.
   - Playlists: its 6 files moved with their history (this repo's #30, Vibe #379), their tests run here, and Vibe compiles them through the template. It depends on AudioTypes and `core/Common`. Its tests read and write entries. Vibe keeps its rows made from entries, the session mirror, and the folder walk, which moves as FolderScan.
   - FolderScan: the folder walk's 4 files moved with their history (this repo's #32, Vibe #385), their tests run here, and Vibe compiles them through the template. `FolderOpenSort.h` came with the walk, and Vibe's settings kept the orders' stored identifiers. It depends on AudioTypes, FileLoading, Playlists, and `core/Common`. Its tests read entries. Vibe keeps its rows made from entries, the handlers it installs, and the test of its own `TrackCommands`. Vibe's file-name search, `FileSearchIndex`, did not move. Since step 9 it calls the catalog scan.

   **Done when** the moved tests pass, and Vibe's benchmarks of the moved code stay inside their no-change bands. Done 2026-10-22: the five pieces moved in four pairs (this repo's #28, #30, #32, and #35, Vibe #378, #379, #384, and #385). Each of Vibe's pull requests reran its benchmark outliers and found each inside its own band. Three moves also compared the running app through the debug channel: PlayQueue and Playlists, Metadata, and FolderScan. Each time, a Debug build before and after the move opened the generated test audio folder into the same playlist. FolderScan's comparison did so under each of the three folder orders. Tags' move made no such comparison.
7. `waveform/`: Waveform, WaveformStyles, WaveformLoading, WaveformView, and the indicators of `ui/Controls`. Controls' map row then drops macOS only, and the piece gains an iOS target. **Done when** Vibe's waveform benchmark pictures are byte-identical and the mac window's screenshots match. On iOS, the `vibe-waveform` probe draws identical pictures, laid out as the scrubber lays them out, and the scrubber's hosted tests pass. Done 2026-10-22: the four pieces and Controls' indicators moved in five pairs (this repo's #31, #33, #36, #37, and #42, Vibe #380, #383, #386, #387, and #391). Every benchmark picture Vibe dumped stayed byte-identical across the engine's move (4,058 files, Vibe #380) and the styles' move (4,042 files, Vibe #386). The styles' comparisons and the loader's probe comparison span AudioWaveform's move too. The mac window's screenshots stayed identical through the debug channel (Vibe #391). For iOS, the probe's pictures stayed identical, and the scrubber's tests passed in Vibe's hosted iOS app, at every move but AudioWaveform's. No move compared screenshots of the running iOS app.
   - Waveform: the 6 files of Vibe's `Packages/WaveformCore` moved with their history (this repo's #31, Vibe #380), their tests run here, and Vibe compiles them through the template. The headers left the package's `include/`, since every consumer spells them by basename. `Package.swift` did not move, so `swift test` for this code ended with the move. The template links Accelerate and `libcompression` through linker flags, since its sources are all C++. Vibe's `AudioWaveform.h` and `.mm` followed with their history and their tests (this repo's #33, Vibe #383): the `AudioWaveform` name, the mono mix, and `CodableAudioWaveform`. The template then lists Common for the entry's log. The entry's tests name observers' identifiers of their own, since how Vibe reads its tempo and key is Vibe's.
   - WaveformLoading: the loader, the cache, the observers, and their two seams, 12 files, moved with their history and their tests (this repo's #37, Vibe #387). Vibe compiles them through the template. The load timing had stayed in Vibe since step 2. The loader was its only writer, so it became the loader's seam, `AudioWaveformLoader+Debug.h`, and Vibe's debug verbs read it from here. The cache's seam takes a playable item where it took a URL, so the app makes its own row. The tests write their own files and run over `VibeTestTrack`, so none stayed in Vibe. Vibe's binding of its tempo and key to the decode stays in Vibe (rule 5).
   - WaveformStyles: its 23 files moved with their history (this repo's #36, Vibe #386), their tests run here, and Vibe compiles them through the template. The theme and the zoom math came with the renderers, since the renderers read both. The renderer tests came too, with the waveforms they build bin by bin. Vibe keeps its mapping from its settings onto the theme, and the views. `WaveformAccessibility.h` stays with the views, since only they read it.
   - WaveformView: its 13 files moved with their history (this repo's #42), their tests run here, and Vibe compiles them through the template (Vibe #391). The mac view is its `Mac/` half, the iOS scrubber its `iOS/` half, and the accessibility contract both views share sits between them. The mac view's seam came beside its class (rule 8). The mac view's tests run over a theme provider of their own, since Vibe's settings are Vibe's. The scrubber's tests need Vibe's hosted iOS app, so they stay in Vibe. The views show the loading control but import no loader, so the piece does not depend on WaveformLoading. Vibe keeps its mapping onto the theme, and the shells that push each view its settings.
   - Controls' indicators: the equalizer bars, their level source and rules, the loading control, its math, and its row view, 16 files with their tests, moved with their history in the same pull request (this repo's #42, Vibe #391). They are Controls' shared files. The map row dropped macOS only, and `Controls-iOS` builds them. The equalizer's seam came beside its class. The level source stayed out of Meter, since the meter never imports it.
8. `tools/strings`: Vibe's strings extraction and catalog checks, reading each app's registry, catalogs, and names from a config file. Done 2026-10-22: its 3 scripts moved with their history (this repo's #40, Vibe #389), and Vibe runs them from here with its own config. A prep commit in Vibe made them read the config, a bash file they source. Vibe's widget catalog became the config's optional subset. Every message and every catalog Vibe's gates write stayed the same. The piece is scripts, so it has no template and no targets, and the checker learned that. Its self-test runs the scripts over a tiny app of its own, `make test-strings`, and CI runs it.
9. The catalog scan ([Scanning a catalog](#scanning-a-catalog)), a change of behavior after FolderScan's move. Done 2026-10-23 (this repo's #56, Vibe #405).

**Done when** a minimal consumer here, grown from `Tests/Consumer/`, uses the real templates with objects and strings of its own. It plays repeated queue entries and a CUE window, cancels a cloud open, roots a metadata cache of its own, and hits the waveform cache. Done 2026-10-23: the consumer does each of these with a row of its own, through the templates an app lists (this repo's #50). The boundary check's paragraph on the minimal consumer says what each check does.

**The other app's first slice starts after this phase.** It scans a folder, lists its songs, and plays a queue.

### Phase 4: the tag fields

The other app's library needs fields Vibe never reads. Before this phase, `AudioTrackMetadata` held title, artist, format, bitrate, sample rate, duration, and tagged tempo and key. This phase adds:

- album, album artist, genre, year, track number and count, disc number and count, and composer
- the compilation flag
- the release and recording identifiers, such as MusicBrainz's, where a file carries them
- FLAC's audio MD5, from its STREAMINFO header, where the encoder wrote one
- the loudness tags: ReplayGain's track and album gain and peak, Opus's R128 track and album gain, and Apple's Sound Check

The parse is TagLib's, which already reads title and artist. The metadata archive's version moves, so an entry without the fields is a miss. **That costs every Vibe user one re-parse of their files**, so it ships in an announced Vibe release. Vibe reads none of the fields.

**This phase also decides album grouping.** Grouping by album title alone merges unrelated releases called "Greatest Hits". The key is the release identifier where present. Otherwise it is album artist, album, and year, with the track artist standing in when album artist is missing. A compilation groups by its album under one album artist, never splitting by track artist. The phase writes those rules as a tested `*Rules.h` decision, with fixtures for each case.

**Done 2026-10-23 (this repo's #52, Vibe #400).** The parse reads every field above from the property map it already built for the tempo and the key. TagLib gives each format's frame or atom one key there, so one lookup serves every format. `media/Metadata/AGENTS.md` lists the names each format carries. The wrapper reads FLAC's audio MD5 from STREAMINFO. No field needed a TagLib feature the vendored subset lacks, and TagLib is unchanged. The reads stayed in the parse, not behind the wrapper. A record of fields in Tags would be a second copy of `AudioTrackMetadata`'s. The archive moved to v8, so every older entry is a miss. Each field has a parse fixture of its own in each format that carries it, and each format's fixture carries all of its fields at once. The grouping is `AlbumGroupingRules.h`, with a case for each rule. CoreAudio's fallback, for CAF and W64, still reads only the title and the artist.

### Phase 5: what a library app adds

Two changes of behavior, each its own pull request with its own measurements:

- **WaveformLoading's scan requests** ([Analyzing many files](#analyzing-many-files)).
- **A gain per file through a gapless splice, in Player.** The gapless successor shares the current voice, so a gain per voice is not enough. The gain changes on the exact frame where one file ends and the next begins. It runs on the audio thread under the render's realtime rules. **Done when** a render test shows the gain change on the boundary frame, and a soak run passes.

### Phase 6: grow from reuse

Each remaining candidate moves when a second app needs it, with the cuts it was waiting for:

- **NowPlaying and Updates, by the other app's first release.** The rest of seam 19 comes with NowPlaying, and Updates' part of seam 21 with Updates. NowPlaying moved on 2026-10-22: its 5 files moved with their history (this repo's #41, Vibe #390), their tests run here, and Vibe compiles them through the template. It took the track's source key, title, artist, and image as values, so it needed no snapshot type and no edge to AudioTypes. On 2026-10-25 its update's ten values became one record the app fills, `VibeNowPlayingRecord`. That record is the snapshot, made of plain values, so the piece still has no edge to AudioTypes. On 2026-10-26 the record became a plain Objective-C class, since Swift cannot import a C struct with object fields.
- **HTTP, RemoteFiles, and ShareLinks**, when the other app adds a server source. Cut 2 and seam 20 come with them.
- **SandboxAccess, AppOpening, DebugChannel, and iOSDriver**, each with its part of seam 21, when a consumer needs it.
- **The pitch fader** joins `ui/Controls` with its part of seam 21. It moved on 2026-10-23 in this repo's #51 and Vibe #399. The fader and its panel joined `ui/Controls`' `Mac/` half. Their 4 files and their test moved with their history, the test runs here, and Vibe compiles them through Controls' template. Their part of seam 21 was four values, which a prep commit in Vibe turned into pushes. The panel takes its title, the fader's VoiceOver label, one formatter for its readout and the fader's spoken value, and its corner radius. So Controls' map row and template are unchanged.

**Wave 10 moved the rest but the pitch fader on 2026-10-23**, in this order:

1. DebugChannel and iOSDriver moved in this repo's #44 and Vibe #393. Their 7 files moved with their history, and Vibe compiles them through their templates. Two prep commits in Vibe came first. The channel's one reach into Vibe, the transport verbs' reply, moved to Vibe's verbs. The driver takes the app it drives, a relaunch's arguments, and the pinched view from its environment. Vibe had no tests of the channel, so its tests are new here. The minimal consumer answers one command through it. The driver builds as a UI-testing bundle with no host app, since it drives an app by bundle identifier.
2. HTTP, RemoteFiles, and ShareLinks moved in this repo's #46 and Vibe #394. Their 27 files and the tests' `HTTPStub` moved with their history, their tests run here, and Vibe compiles them through the templates. The fake HTTP host joined ShareLinks (rule 8). Its serving engine moved on to HTTP later, so HTTP's and RemoteFiles' test bundles no longer list ShareLinks. `HTTPStub` moved later from `Tests/Support` to HTTP's tests. Its iCloud lookup fixtures went to ShareLinks' tests as `ICloudLookupFixtures.h`. The link store, the Dropbox mirror and client, and every debug verb stay in Vibe. The 2 GB link budget moved from `LinkRules.h` to Vibe's link store, since it is Vibe's choice. The error domains and queue names start `vibe-libs`. The kept part's xattr keeps Vibe's name, since parts on disk carry it.
3. Updates and the Sparkle framework moved in this repo's #45 and Vibe #395. Updates' 3 files and the framework moved with their history, their tests run here, and Vibe compiles them through the two templates. A prep commit in Vibe turned its category on the app's delegate into `VibeUpdater`, one class the app makes, feeds, and starts. The app passes the feed override and the beta switch, sets the check interval, and targets Check for Updates… at the class's controller. The framework is unmodified. Its template links, embeds, and signs it. A configuration with no updater excludes it and `VibeUpdater.m` by name.
4. SandboxAccess moved in this repo's #47 and Vibe #396. Its 7 files moved with their history, their tests run here, and Vibe compiles them through the template. Its part of seam 21 was three reaches. The app now passes the grant panel's text, and the defaults and the key its grants are stored under. The store has no shared instance, so the app keeps the one it makes. The store treated ~/Music as granted, which assumed the app holds the music entitlement. Since 2026-10-25 the app names the folders its entitlements grant.
5. AppOpening moved in this repo's #48 and Vibe #397. Its 8 files moved with their history, their tests run here, and Vibe compiles them through the template. Its part of seam 21 was two values. The coordinator hands back the app's rows as an untyped array, and the argument scan takes the options whose values it skips. So it depends on nothing but `core/Common`, as its map row says.

## What the other app needs, and when

One list of what the other app waits on, so no prerequisite stays "later". A move and a new capability stay separate rows. Each row records the commit here that delivered it.

| The other app's milestone | Delivery here | Kind | Phase | Proven by | Delivered at |
| --- | --- | --- | --- | --- | --- |
| First slice: scan a folder, list its songs, play a queue | Player, the four waveform pieces, Metadata, PlayQueue, DiskCache, and FileLoading with its fake cloud | move | 3 | the minimal consumer | c0b8210 (#50) |
| First slice | Playlists and FolderScan | move | 3 | Vibe's walk and CUE tests, moved here | b02ac08 (#30) and 79487ed (#32) |
| First slice | the catalog scan | behavior | 3 | the tests in Scanning a catalog | 2d8ff5a (#56) |
| First slice, from its first UI string | `tools/strings` | tool | 3 | the consumer's own catalog passes the checks | 9aef74c (#40) |
| First slice: tags for its index, with no download | Metadata's reads by URL, with a read policy | behavior | 3 | `AudioTrackMetadataReadingTests`, and a probe of the I/O policy on iCloud Drive and Dropbox | |
| First slice: the waveform in a titled window's player bar | WaveformView's `dragsWindow` and `accessibilityValueProvider` | behavior | 3 | `WaveformViewTests`' drag and spoken-value tests | 820660f (#78) |
| First slice: a seek from the player bar at a gapless splice | `AudioPlayer`'s `seekToPosition:ofTrack:` | behavior | 3 | `testASeekNamingTheOutgoingTrackAfterASpliceIsDropped` | |
| Full app: song matching and leveling | the tag fields, identifiers, audio MD5, and loudness tags | behavior | 4 | a parse fixture for each field | 5cca1ea (#52) |
| Full app: background analysis | WaveformLoading's scan requests | behavior | 5 | a throttled source yields within one block | |
| Full app: leveling from tags | a gain per file through a gapless splice | behavior | 5 | the boundary-frame render test | |
| First release | NowPlaying and Updates | move | 6 | each app's media keys and update check | NowPlaying at 36ff73d (#41). Updates at ccea3ae (#45). |
| Any mac app's opens, when it needs them | AppOpening | move | 6 | the coalescer's and the coordinator's tests, and the minimal consumer's split open | 8b1418e (#48) |
| A server source | HTTP, RemoteFiles, and ShareLinks | move | 6 | Vibe's transfer, store, and link tests, moved here | 2f62ff4 (#46) |

Nothing else is scheduled for the other app. The shell pieces are scheduled for a third app, on the shell track. Portable rewrites wait until a consumer needs them.

### Later

- **Portable rewrites.** Each is its own project, with its own measurements: WaveformStyles as C++ that paints pixels, which a waveform plugin needs; DSP, Analysis, Tags, and Playlists cores in C or C++; fallbacks for vDSP, simd, and Compression. Apple's LZFSE is open source under BSD, so it can be vendored and waveform archives stay readable everywhere. The Apple path keeps Accelerate, and `perf.py compare` proves it unchanged.
- **The rest of tools/.** Vibe's release, notarization, App Store upload, Homebrew, and layout-check scripts, and its stress and performance harnesses, are general too. Each moves once it takes its app's names and paths from a config file, as `tools/strings` does in Phase 3.

### Streaming is mostly built

Vibe already has HTTP transfers, ranged reads, remote placeholders, opens that play while a file streams, and render tests through that path against a stub server (`AudioPlayerRenderLinkTests`). A server source such as OpenSubsonic still needs:

- **Authentication.** OpenSubsonic signs each request with a salted token.
- **Catalog integration.** A server's songs become catalog entries with no bookmark and no local path.
- **Identity.** An entry is the server plus the server's item ID, never a URL, since stream URLs carry the token.
- **The original bytes.** OpenSubsonic transcodes unless asked not to, so every stream request passes `format=raw`. A transcoded stream would change the waveform, the analysis, and bit-perfect output.
- **Compatibility tests** against Navidrome, Gonic, Airsonic, and Ampache, which answer the same API differently.

That work belongs to the app that ships the source. FileLoading and Player moved in Phase 3. HTTP, RemoteFiles, and ShareLinks moved in Phase 6 (this repo's #46).

## New types

The cuts add these small types. Each replaces a dependency on an app class:

- the playable-item protocol
- Metadata's holder protocol
- the protocol of a handle the file loader serves
- a waveform decode's observer: its identifier, a sink for each decode, and the sink's result
- the record of a playlist entry, from Playlists. It also carries the M3U writer's fields, the duration, display title, and display artist, since the writer stays in Playlists.
- the catalog scan's verdict and its read policy, from FolderScan
- the settings pane's effects sink, a block over an integer the app interprets, from SettingsWindow
- the typography slot table, from Graphics

One more replaces no app class: the Now Playing update's record, from NowPlaying. It took the place of the update's ten parameters.

## TRAPs

- **A template's settings replace a value the target takes from a settings group.** They join only a value in the target's own `base`. So an app sets its own header search paths in `base`, never only through a group (the header of `vibe-libs.yml`).
- **A checkout without the submodule compiles nothing from here and fails late.** Every consumer's `make project`, benchmark worktrees, and CI checkouts must update it.
- **YAML anchors do not cross `include:` files.** A consumer's own flag anchors cannot reach a template's entries. Every flag lives in its template.
- **The headermap hides a crossed boundary.** In any project holding two pieces, an import by basename resolves across them. Only this repo's headermap-off bundles make the compiler refuse.
- **TagLib and libvorbis both answer `<vorbis/vorbisfile.h>`.** TagLib keeps its own under `taglib/ogg`. An app's header search paths follow the order of its templates, so an app that takes both lists `VibeLibsVorbis` before `VibeLibsTaglib`. An app's headermap would also let libvorbis's `vorbisfile.h` answer for TagLib's by basename. So the vorbis and ogg templates add only their C files to an app's project.
- **`xcodegen dump` keeps a target's templates as fields, not expanded.** It rewrites their paths relative to the app. A tool that builds a new target from a dumped one must copy `templates` and `templateAttributes`, or it builds without the pieces. Vibe's `perf.py` copies both.
- **Vibe's analyzer gate drops findings by path substring** (`scripts/build/analyze.sh`). It drops `/ThirdParty/` for Vibe's own vendored code. Since Vibe #352, it also drops `/third_party/`, where vendored code sits here. A vendored library anywhere else would fail the gate.
- **A queue, a player, or a cache that compares items by content merges duplicates.** Two entries for one file are two entries. Shared work matches by source key, and a persisted entry by disk key.

## Costs

- **44 pieces in the tree, 34 first-party and 10 vendored, and 32 marked on the first path.** Each is a maintenance choice: a template, a doc, isolated builds, and a row in the map. A piece needs a consumer that gains from taking it alone. Each template lists its own dependencies, which keeps a consumer's list short.
- **One copy of each thing that could drift.** Each vendored library's flags live in its template. Each piece's sources are listed once, in its template. The map is the plan's table. Each template's `templates:` list repeats part of it, and the checker fails when a template lists more than the map allows.
- **Most engine changes also change app code.** Since 2026-04-01, 232 commits changed Vibe's engine, and 167 of them (72%) also changed Vibe's app code. After a move, each is a commit here, then a submodule bump. One editing session covers both through the submodule.
- **Many changes span pieces.** 90 of those commits (39%) changed more than one of the old products. That is why this is one repo and not one per piece.
- **Agent docs split across two repos.** An agent in an app must read this repo's `AGENTS.md` before changing a piece. Each app's root doc says so.
- **Vibe's two test source lists stay until each piece's tests move here.** Vibe's tests build production sources with their own flags, which is the reason compiling in was chosen.
