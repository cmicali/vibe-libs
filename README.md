# vibe-libs

A toolbox of small libraries for macOS and iOS apps. Each library is a piece an app can take on its own. Take the whole audio player, or only the waveform data, or only TagLib.

The first pieces come from [Vibe](https://github.com/cmicali/vibe). Anything in Vibe that another app could use is a candidate. It moves when a second app needs it.

## The pieces

**The first forty-five pieces are here.** Each came from Vibe. The ten under `third_party/` are the libraries Vibe vendored. The plan for the rest is [docs/plan.md](docs/plan.md).

| Piece | What it holds |
| --- | --- |
| `core/Common` | Logging, diagnostics, path and file helpers, file identity, the disk key, and work lanes. |
| `core/Graphics` | Image, color, and font helpers, and the typography slots. |
| `files/FileLoading` | Local, iCloud, and network-share files, read even while they download, and a fake cloud for tests. |
| `files/DiskCache` | A bounded disk cache. |
| `files/HTTP` | Ranged HTTP transfers. |
| `files/RemoteFiles` | A local placeholder for a file on a server, fetched by range. |
| `files/ShareLinks` | The rules for opening a web link, share-link rewrites, iCloud Drive's lookup, and a fake web server. |
| `files/SandboxAccess` | A sandboxed mac app's folder grants, kept as security-scoped bookmarks, with the panel that asks for one. macOS only. |
| `audio/AudioTypes` | The playable-item protocol, the CUE window math, the musical key, format names, and playable extensions. |
| `audio/DSP` | Varispeed, fades, and the resampler. |
| `audio/Analysis` | Tempo and key detection. |
| `audio/OutputDevices` | The mac's output devices and the iOS audio session. |
| `audio/FX` | DJ effects. |
| `audio/Meter` | Live band levels. |
| `audio/Decode` | The audio file handle and the decoders it hosts. |
| `audio/Player` | Gapless, crossfading, bit-perfect playback, with its device and route recovery halves and a manual render pump. |
| `media/Tags` | The TagLib wrapper: tag fields and embedded art bytes. |
| `media/Metadata` | The tag record, its cache and scan, embedded art and thumbnails, and folder art. |
| `media/PlayQueue` | Play order, shuffle, and repeat. |
| `media/Playlists` | CUE and M3U readers, and an M3U writer. |
| `media/FolderScan` | The folder walk. |
| `waveform/Waveform` | The waveform summary, its reads, raster, and archive. |
| `waveform/WaveformLoading` | The waveform loader, its cache, and the observers on its pass. |
| `waveform/WaveformStyles` | Each style's look, its colors, and the morph engine that eases between styles. |
| `waveform/WaveformView` | The mac waveform view and the iOS scrubber. |
| `ui/Controls` | The loading and equalizer indicators on both platforms. On the mac, buttons, drawn sliders and switches, image views, a link label, and the pitch fader. |
| `ui/SettingsWindow` | A System Settings window with a sidebar, search, history, and form views. macOS only. |
| `ui/Shortcuts` | Remappable shortcuts and their recorder pane. macOS only. |
| `system/NowPlaying` | A bridge to the system's Now Playing info and remote commands. |
| `system/AppOpening` | One open request from the batches the mac splits it into, delivered in order. macOS only. |
| `system/Updates` | Sparkle for a direct-download mac app. macOS only. |
| `dev/DebugChannel` | Drive and inspect a running debug build from a script. On the mac, its CLI client too. |
| `dev/DebugVerbs` | The debug verbs every app's channel answers the same way, and the mac's synthetic input. |
| `dev/iOSDriver` | Taps, drags, and pinches in the iOS simulator, for scripts. iOS only. |
| `tools/strings` | An app's strings extraction and catalog checks, configured per app. Scripts, not code an app compiles. |
| `third_party/taglib` | TagLib, which reads and writes tags. |
| `third_party/dr_mp3` | dr_mp3, which decodes MP3, MP2, and MP1. |
| `third_party/dr_flac` | dr_flac, which decodes FLAC. |
| `third_party/dr_wav` | dr_wav, which decodes WAV, W64, RF64, and AIFF. |
| `third_party/r8brain` | r8brain-free-src, the resampler. |
| `third_party/PINCache` | PINCache, the cache under DiskCache. |
| `third_party/PINOperation` | PINOperation, PINCache's queues. |
| `third_party/ogg` | libogg's page reader. |
| `third_party/vorbis` | libvorbis, which decodes Ogg Vorbis. |
| `third_party/Sparkle` | Sparkle, the prebuilt updater framework. macOS only. |

## How an app uses it

An app adds this repo as a git submodule at `vibe-libs/`. Its XcodeGen `project.yml` includes `vibe-libs/vibe-libs.yml` and lists the pieces it wants as templates on its targets. The pieces' sources compile into the app as its own files, so they build exactly as they would in the app's own tree.

## License

Apache 2.0, in `LICENSE`. The libraries under `third_party/` keep their own licenses. [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) lists each one and the license it is used under.
