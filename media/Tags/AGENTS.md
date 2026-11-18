# media/Tags

TagLib's fields and embedded art bytes. It depends on `third_party/taglib`, on `audio/AudioTypes` for the format names, and on `core/Common` for the log macros. It holds `TagLibAudioFile`, the TagLib wrapper, in Objective-C++. It came from Vibe. It reads no app's settings, strings, or types.

`media/Metadata`'s parse is its one user. It reads the title, the artist, the audio properties, and every tag field from the wrapper's `TagLib::File` (`media/Metadata/AGENTS.md`, The tag fields). What it does with them, the cache, the scan, and the artwork, is `media/Metadata/AGENTS.md`.

## How an app uses it

**`TagLibAudioFile` opens a file the way `TagLib::FileRef` would.** It answers the parsed `TagLib::File` and its tag, or null when no parser takes the file. `fileTypeForTagLibFile` names the format, as `audio/AudioTypes` spells it. `albumArtDataFromTagLibFile` answers the embedded picture's bytes. `audioMD5FromTagLibFile` answers a FLAC's audio MD5 from its STREAMINFO block, or nil for the zeros an encoder writes when it computed none. `VibeTagLibReadEmbeddedArt` opens a file for its art alone, with no audio properties. It answers NO for a failed read: no parser took the file, or TagLib threw. YES with nil art is a file that carries none. An app keeps the two apart, so a failed read is never mistaken for a file without art.

**The header is C++**, so only Objective-C++ and C++ can include it. A file that includes it also needs TagLib's header paths, which the template brings. An app that takes it builds C++ as C++17 or later, since TagLib's sources are C++17. **TRAP: an app that also takes `VibeLibsVorbis` or `VibeLibsDecode` lists this template after them**, as it would `VibeLibsTaglib`. `taglib/ogg` holds TagLib's own `vorbis/vorbisfile.h`, and the first search path wins (the template's comment).

**A read blocks, and an entered read cannot be cancelled.** Call it off main. A corrupt tag can make TagLib throw. `VibeTagLibReadEmbeddedArt` catches it. A caller of the constructor wraps its own reads in a `try`, as `media/Metadata`'s parse does, since an uncaught throw on a worker ends the process.

## Detection

**`TagLibAudioFile` stands in for `TagLib::FileRef`**, whose detection references every format parser TagLib has. `third_party/taglib` vendors only some. The order is FileRef's: the extension's parser, then `isValid()`, then a sniff of the content. The extension map is FileRef's, plus `wave`, `bwf`, and `qta`, a QuickTime container `MP4::File` parses. An `.ogg` or `.oga` holds Vorbis or Opus, told apart by a sniff. The content sniff tries MPEG last, since its sniff takes frame sync bytes inside other formats for MP3. An update of TagLib re-checks the map against `fileref.cpp`.

**TRAP: the MPEG, AIFF, and WAV parsers take another format's bytes as valid.** So the extension's parser alone would read a FLAC named `.mp3`, or an AIFF named `.wav`, with no tags and no audio properties. As FileRef does since TagLib #1490, an AIFF or WAV extension first asks its parser's `isSupported`. An MPEG extension, which has no signature, first looks for another container's after any ID3v2 tag. On a mismatch the content sniff decides, and its stream is rewound. When the sniff finds nothing, the extension's parser reads the file. A WAVE whose format is MPEG audio stays MPEG.

**INFO text reads as UTF-8 when it is valid UTF-8, and as Latin-1 otherwise.** INFO declares no charset, and TagLib 2.3.2 answers an empty string for text that is not UTF-8, so Latin-1 text from Windows tools read as nothing. The wrapper installs its own `RIFF::Info::StringHandler` before its first parse. TagLib keeps one handler for the process, so an app that installs its own replaces this one.

**TRAP: a refused parser leaves the stream anywhere, and RIFF reads from `tell()`.** The constructor rewinds before the sniff. Without it a WAV named `.m4a` parses with no tags.

**TRAP: no Ogg stream parses as FLAC.** TagLib's FLAC sniff takes a stream with `fLaC` near its start, which FLAC in Ogg carries in its first page. `audio/Decode` refuses that file at the parser open, so the wrapper refuses it too. An app that shows a parsed file as playable would otherwise show one that cannot play.

Without `readProperties`, no audio properties are parsed. The art read never uses them, and no format's validity depends on them.

## Reading by range

**With a `VibeTagByteRangeRead`, the wrapper reads the file's bytes through the caller's block instead of from disk.** The caller passes the file's length too. `media/Metadata` passes one for a remote placeholder, a file whose bytes are on a server, so its tags and art are read without downloading the song. The block runs on the reading thread and blocks.

`VibeRangedStream` fetches 64 KiB blocks, one request per run of missing blocks, and keeps them for the stream's life. The first read fetches up to 384 KiB, so nearby art costs no second request. Later requests follow the parser's reads. A tail read can therefore fetch the file's end alone. A server must honor ranges, or the reader the app passes must skip to the offset itself.

**TRAP: a failed or short fetch throws.** The parse's `try` turns it into a failed parse. Returning short would let TagLib build a tag from bytes that were never read.

## The debug listener

`VibeInstallTagLibDebugListener` routes TagLib's debug output to the log as warnings. TagLib's own listener writes to `std::cerr` unsynchronized, so two workers race on the stream. It is defined only where `NDEBUG` is not, since there `TagLib::debug()` is a no-op. An app calls it once, under the same condition.

## Tests

`Tests/media/Tags/` holds the tests of the detection: the extension's parser first, then the content sniff, with an ID3v2 tag before a FLAC, and FLAC in Ogg refused. They write their own untagged files with AVFoundation and an MP3's frames. Misnamed files check the header before the extension's parser. A WAV written by hand checks how INFO text decodes. The tests of the parse over the wrapper are `media/Metadata`'s: each format's tags and facts, the art, the range read through a placeholder's backend, and the fuzz family. The minimal consumer tags a WAV with TagLib, reads its title back through the wrapper, and reads its picture's bytes through a byte-range reader.
