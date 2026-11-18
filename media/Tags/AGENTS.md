# media/Tags

TagLib's fields and embedded art bytes, read and written. It depends on `third_party/taglib`, on `audio/AudioTypes` for the format names, and on `core/Common` for the log macros. It holds `TagLibAudioFile`, the TagLib wrapper, in Objective-C++, and `VibeTagWriter`, the in-place write of a file's fields and cover (Writing, below). It came from Vibe. It reads no app's settings, strings, or types.

`media/Metadata`'s parse is its one reader. It reads the title, the artist, the audio properties, and every tag field from the wrapper's `TagLib::File` (`media/Metadata/AGENTS.md`, The tag fields). What it does with them, the cache, the scan, and the artwork, is `media/Metadata/AGENTS.md`.

## How an app uses it

**`TagLibAudioFile` opens a file the way `TagLib::FileRef` would.** It answers the parsed `TagLib::File` and its tag, or null when no parser takes the file. `fileTypeForTagLibFile` names the kind, the codec's name as `AudioFileFormat.h` defines it: AAC, ALAC, or FLAC in an MP4 reads AAC, ALAC, or FLAC. `tagLibFileCarriesID3v2` answers whether the tag is ID3v2, which MPEG, WAV, and AIFF carry, by the parser that took the file. `albumArtDataFromTagLibFile` answers the embedded picture's bytes. `audioMD5FromTagLibFile` answers a FLAC's audio MD5 from its STREAMINFO block, or nil for the zeros an encoder writes when it computed none. `bitsPerSampleFromTagLibFile` answers a lossless stream's bits per sample: FLAC, ALAC or FLAC in MP4, PCM or float WAV, and AIFF. It answers 0 for a lossy codec, whose sample entry may still name 16 bits. `VibeTagLibReadEmbeddedArt` opens a file for its art alone, with no audio properties. It answers NO for a failed read: no parser took the file, or TagLib threw. YES with nil art is a file that carries none. An app keeps the two apart, so a failed read is never mistaken for a file without art.

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

## Writing

**`VibeTagWriter.h` writes a file's tag fields and front cover in place.** `VibeTagLibWriteFields` sets or removes fields by TagLib's property-map name. `VibeTagLibWriteFrontCover` sets the front cover from JPEG or PNG bytes, or removes it. `VibeTagLibWriteTags` does both in one save. `VibeTagLibReadFields` reads the fields back by the names they were written with. The header is plain Objective-C, so Swift and a `.m` call it. **A write blocks**, as a read does, so call it off main.

**Only the fields named change.** An empty array removes a field. The writer edits the frames, atoms, or comments of each named field, then saves. It never sets a tag's whole property map, which would drop or rewrite what the map cannot name. Other fields, unknown frames and atoms, other pictures, and the audio stay as TagLib found them. TagLib reuses an ID3v2 tag's padding when the new tag fits.

**`VibeTagFields.h` names the fields** an app edits, as constants that `media/Metadata` and an app share. Their values are TagLib's keys, so a write and a parse spell them alike.

**The write is in place and not atomic.** A save that fails, or a throw, can leave the file part written. So an app clones the file beside itself, writes the clone, reads it back, and swaps it in. `testAnOpenHandleReadsTheOriginalAfterARenameOverIt` and `...AfterARenameSwap`, in `audio/Decode`'s tests, show that a handle open on the original reads the original's bytes to their end after either swap, in every decoder's open.

**A failure is an `NSError` in `VibeTagWriteErrorDomain`, and no C++ exception leaves the call.** The arguments are checked before the file opens: a field name that is empty, holds `=` or a control character, or is `PICTURE`, and a cover that is empty or not `image/jpeg` or `image/png`. Then the file must open, for writing, and a parser must take it. A damaged file no parser takes fails there, untouched. **TRAP: TagLib's MPEG parser takes any bytes as valid**, so the writer also refuses a file with no MPEG frame. Without it, a text file named `.mp3` gained a tag. Only a throw or a failed save can leave the file changed.

### What each format writes

| Format | Fields | Cover |
| --- | --- | --- |
| MP3 | ID3v2. An existing APE or ID3v1 tag takes the edit too | `APIC` of type front cover |
| FLAC | the Xiph comment block. A FLAC's own ID3 tags are left | a `PICTURE` block of type front cover |
| Ogg Vorbis and Opus | the Xiph comment packet | `METADATA_BLOCK_PICTURE` of type front cover |
| MP4 and M4A | the `ilst` atoms. A field TagLib has no atom for is a `----:com.apple.iTunes:` atom | the first `covr` entry |
| WAV | the `ID3 ` chunk. An existing `LIST` `INFO` chunk takes the edit too, for the fields INFO holds | `APIC` in the `ID3 ` chunk |
| AIFF | the `ID3 ` chunk | `APIC` in the `ID3 ` chunk |

**An ID3v2 tag keeps its version.** A 2.3 tag is written as 2.3, and 2.4 as 2.4. A file with no ID3v2 tag, or a 2.2 tag TagLib cannot write, gets 2.4.

Every format holds every field in `VibeTagFields.h`, with these limits:

- **ID3v2.3 holds the original date's year alone**, in `TORY`.
- **TRAP: TagLib drops `TMOO`, `TDRL`, `TPRO`, and `TSST` when it renders ID3v2.3.** So the writer puts a 2.3 tag's mood in `TXXX:MOOD`, as Picard does, and it reads back as `MOOD`. A 2.3 tag that already held one of those frames loses it at any write.
- **MP4 holds the tempo and the compilation flag as whole numbers.** A value that is not one fails with `VibeTagWriteErrorUnsupportedValue`, and the file is untouched.
- **TRAP: ID3v2, MP4, APE, ID3v1, and INFO hold a total inside its number, as "3/12".** The writer folds `TRACKTOTAL` and `DISCTOTAL` into the number, keeping the half not named. A total with no number writes 0 as the number. `VibeTagLibReadFields` splits them out again. A Xiph comment keeps them apart, and a write of a total there also removes `TOTALTRACKS` or `TOTALDISCS`.
- **ID3v2's `GROUPING` is `GRP1`.** TagLib calls `TIT1` the work, which the writer leaves. `media/Metadata` reads `TIT1` as the grouping when `GRP1` is absent, so a removed grouping may then read as the work.
- **MP4's pictures have no type.** The first `covr` entry is the cover, as the art read answers. Setting it replaces that entry, and removing it leaves the rest. In the other formats, the cover is every picture of type front cover, and other types stay. A file whose cover is typed "other" keeps it, and the read answers it once no front cover is left.
- **MP4's `GENRE` covers `©gen` and `gnre`**, the ID3v1 genre number, so a write replaces both.

**TRAP: TagLib reads the first tag that is not empty.** A new ID3v2 tag holding one field would hide every field of an MP3's ID3v1 or APE tag, or of a WAV's INFO chunk. So a tag the writer creates, or finds empty, first takes the fields the file reads today. A FLAC's empty Xiph comment does the same over its ID3 tags.

**TRAP: TagLib's WAV save rewrites a `bext` or `iXML` chunk at the file's end**, its bytes unchanged.

## Tests

`Tests/media/Tags/` holds the tests of the detection: the extension's parser first, then the content sniff, with an ID3v2 tag before a FLAC, and FLAC in Ogg refused. They write their own untagged files with AVFoundation and an MP3's frames. Misnamed files check the header before the extension's parser. A WAV written by hand checks how INFO text decodes. The tests of the parse over the wrapper are `media/Metadata`'s: each format's tags and facts, the art, the range read through a placeholder's backend, and the fuzz family. The minimal consumer tags a WAV with TagLib, reads its title back through the wrapper, and reads its picture's bytes through a byte-range reader.

`VibeTagWriterTests` writes each format's file and tags it through the writer. Every field and the cover round trip in every format. A write of one field leaves every other field, a custom field, an MP3's private frame, a second picture, and the audio bytes, with a FLAC's audio MD5. A read-only file, a damaged file, and a bad argument each fail with their code and leave the file's bytes. Ogg files are pages built in the test, since no Apple encoder writes Ogg.

`Tests/Fuzz/` also fuzzes this piece by coverage, under sanitizers, through its `tags-*` targets ([Tests/Fuzz/AGENTS.md](../../Tests/Fuzz/AGENTS.md)).
