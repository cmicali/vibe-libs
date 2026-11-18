# audio/AudioTypes

The words every audio piece shares, so a piece that needs one of them needs neither Decode nor Analysis. It holds the playable-item protocol, the CUE window math, the musical key and its color, the file format names, and the playable extensions. It came from Vibe. It depends on nothing, not even `core/Common`, since no file here logs. Each file imports only Foundation, but for two. The format names import `CoreAudioTypes` too, and the key's color imports AppKit or UIKit in its `.m` alone.

## The playable item

**`VibePlayableItem` is what a piece that reads a file takes of an app's item.** That is its file, its window in CD frames, its source key, and its disk key. A piece keeps the item it was given and hands that same object back, so two items for one file stay two items. It only reads it. Nothing in the protocol is about tags, tempo, key, names, or art. Those are the app's. Any object may adopt it.

- **The window** is `cueStart` and `cueEnd`, start inclusive and end exclusive. An end of 0 runs to the file's end, so 0 and 0 is the whole file. It is fixed before the item crosses a thread.
- **`sourceKey` is source identity**: the file's path and its window. Shared work matches on it. It is compared on paths that run every tick, so it must be fixed and allocate nothing. It names what sounds. It is never a path to open.
- **`cacheKey` is version identity**: the disk key of `core/Common`'s `NSURL (Hash)`. It is nil when the file cannot be statted, and the caller then caches nothing. An item may memoize it, stamped with `NSURL.cacheKeyGeneration`.
- **`VibeKeyByAppendingCueWindow`** appends a window to a key, so the windows of one file key apart. A whole file keeps its key. Persisted waveform entries are spelled with it, so the spelling never changes.
- **`fileGain` is optional**: the linear gain to play the file at, for leveling. An item without it plays at 1. It is fixed before the item crosses a thread, as the window is. The player's `PlaybackGainRules.h` guards it.
- **`VibePlayableItemIsFollowedContiguouslyBy`** says one item's next window of the same file begins where it ends. That is one recording, which a player continues without a gap whatever the crossfade.

## The CUE window

**`CueWindowMath.h` turns a window in CD frames into a file's frames, at the file's rate.** A CD frame is 1/75 s. `VibeCueWindow` rounds both ends at the rate. So two rows meeting at a marker round the same point, and they stay contiguous at a rate 75 does not divide. A cue end of 0, or one past the file's end, is the file's end. A window with nothing left is empty.

**TRAP: a length that is only an estimate refuses nothing and cuts nothing short.** A streaming MP3's length is one. The cue end stands, and a window to the file's end reaches at least a frame past its start. Both clamp once the length settles. `VibeCueEndFrame` is the end alone, unclamped, or 0 for a window to the file's end. It is never derived from the length.

## The musical key

**A `VibeMusicalKey` is one integer**: 0 to 11 is the major key on that pitch class, C to B, and 12 to 23 is the minor. An app's waveform cache may archive it, so the encoding never changes. `VibeMusicalKeyFromString` reads the spellings real tags carry: musical names, Camelot, and Open Key. It answers none for anything it cannot read with confidence, so an unreadable tag falls back to analysis. The display names are DJ notation and are not localized.

**TRAP: 0 is C major, not "none".** Every fresh holder must be set to `VibeMusicalKeyNone` (-1) explicitly. A zero-filled field or a message to nil reads as a tagged C major.

**`VibeMusicalKeyCamelotColor` is a key's color around the Camelot wheel** (`MusicalKeyColor.h`). There is one hue per wheel number, with 1 green as on the printed wheel. So keys that mix harmonically sit in neighboring hues, and a relative major and minor share one color. The color resolves per appearance: less saturated on dark chrome, and darker on light, since one fixed color cannot read on both. It is an `NSColor` on macOS and a `UIColor` on iOS. A key that is not valid answers nil, so a caller that colors nothing passes `VibeMusicalKeyNone`. Whether keys are colored at all is the app's setting.

## The format names

**`AudioFileFormat.h` names the codecs and containers**: MP3, FLAC, WAV, and the rest. A name is an identifier. It is compared with `isEqualToString:` and archived in a metadata cache, so it is never localized. `VibeAudioFileFormatForCodec` names a codec from its CoreAudio format ID. A codec with no constant here, PCM among them, answers nil, since its name is its container's.

## The playable extensions

**`PlayableExtensions` lists every audio extension the decoders open**, lowercase. `ordered` lists lossless before lossy. A playlist entry naming a missing file takes the first spelling that exists, so the order picks the replacement. `lookup` is the same set for a membership test. `tagParsed` is the share TagLib parses. The rest, W64 and CAF, take their facts from CoreAudio, which reads only a whole local file.

**An app's document types must not admit a spelling this list lacks.** A claimed type takes in every type that conforms to it. Finder then offers the app a file its open filter drops.

## Tests

`Tests/audio/AudioTypes/` holds the tests of the CUE window, the musical key, the playable item, the format names, and the playable extensions. The CUE window's and the key's came from Vibe. The rest are new here. The key color's tests resolve an `NSColor`, so they sit in `Mac/`. The playable item's tests adopt the protocol in a plain object, so they show any object may. `AudioTypesProbe.m` imports the header-only files, and the iOS target compiles it. The minimal consumer turns a CUE window into a file's frames.
