# media/Playlists

CUE sheets, also embedded in FLAC, and M3U playlists, read and written as records. It depends on `audio/AudioTypes`, for the playable extensions and the CD frame rate, and on `core/Common`, for the path spelling. Nothing here logs. **Today it holds what Vibe moved here.** None of it reads an app's settings, strings, or types.

| File | Owns |
| --- | --- |
| `VibePlaylistEntry.{h,m}` | the record: a file whole, or a CUE sheet's window of one with the sheet's names, plus the length and names the writer's `#EXTINF` line takes. A plain value, made once and never changed, so it crosses threads freely |
| `VibePlaylistFile.{h,m}` | the M3U reader and writer, the text decoding, the entry rungs, and the extensions it expands. `VibePlaylistFile.h` states each method's contract |
| `VibePlaylistFile+CUE.m` | the CUE reader, and the sheet a FLAC carries |
| `VibePlaylistFileInternal.h` | the entry rungs and the name cleanup the two files share. Nothing else imports it |

## Records

**The readers return `VibePlaylistEntry` records, and the writer takes them.** An app makes its rows from entries, and entries from its rows, in one place of its own. The writer takes each entry's length and display names, so the app fills them in. The readers ignore `#EXTINF`, so they make every entry with the shorter initializer. The window's arithmetic is `audio/AudioTypes`' `CueWindowMath.h`, which an app's player shares.

The playable extensions are `audio/AudioTypes`' `PlayableExtensions`. The entry rungs read it, so an entry can never resolve to a format the decoders do not open. `media/FolderScan`'s walk filters with the same list.

## Reading one

**Each entry resolves through fallback rungs.** The rungs are the named path, then its basename beside the playlist (for a Windows-absolute path), then both again under each playable extension (for a rip transcoded after the sheet was written). A caller that just listed the folder passes its listing (`knownFiles`, grouped by `knownFileKeyForPath:`), and every rung looks its candidate up there before the disk. An entry readable nowhere still yields its primary candidate. That lets the caller tell a sandbox denial from a missing file, which is what lets an app ask for a folder grant.

**TRAP: against a listing every rung answers in the listing's spelling, never its own.** A walk claims files by exact URL. The volume folds case and Unicode normalization, and NSURL decomposes what it is handed. A probe would find the listed `01 - Title.flac` under the sheet's `01 - title.flac`, and the file would also play whole beside its rows. `testEveryResolutionRungClaimsTheListedFileUnderEverySpelling`, in `media/FolderScan`'s tests, covers every rung.

**A CUE sheet reads as entries** (`cueEntriesInText:sheetURL:resolvingFile:`, one parser with the resolution injected). Each kept AUDIO TRACK becomes one entry, a window of its FILE in CD frames, with the sheet's TITLE and PERFORMER. Only those two fields are read. Every file keeps all its audio. Its first entry starts at frame 0, a pregap plays at the end of the entry before it, and a FILE with no surviving track plays whole. The drop rules are in `VibePlaylistFile.h`. `testCueFuzzedMutationsKeepRowsPlayable` holds every window playable under mutation.

**A FLAC can carry its own sheet** (`cueEntriesEmbeddedInFLACAtURL:`). It may be the `CUESHEET` tag's text or the binary CUESHEET block. The text wins, since only it has titles. The block is rewritten as text for the one parser, with sample offsets rounded to CD frames. The first FILE line maps to the FLAC itself, and any other is dropped. The reader reads the metadata blocks and nothing else. Whether a file is worth opening for its sheet is the caller's decision. `media/FolderScan`'s walk opens a FLAC of 100 MB or more that no sheet beside it claimed, and never a cloud placeholder.

An opened playlist that lists nothing playable gives no entries. A sheet naming an image the decoders do not open (APE, WavPack) lists nothing. An M3U gives file references only, and `#EXTINF` is ignored. The exception is the cue entries the writer wrote into it (below).

These files come from other people's software, so the next two traps are load-bearing.

**TRAP: BOM-less UTF-16 must be decided *before* UTF-8 is tried.** A UTF-16 sheet of ASCII names has no byte above 0x7F. It decodes as UTF-8 *successfully*, with a NUL between every character, and the playlist opens empty. The order is BOM'd UTF-16, BOM-less UTF-16 signature, UTF-8, NUL-based UTF-16 fallback, CP1252, Latin-1. Latin-1 maps every byte, so a non-empty file always decodes.

**TRAP: a name may not reach `NSURL` carrying a NUL or an unpaired surrogate.** Both turn up in truncated and mis-encoded files. `NSURL` answers nil for such a component, and a nil candidate raises on the caller's worker. `VibeStrippedOfUnpathableCharacters` drops them while the name is still a string. A `%00` in a `file://` M3U entry is dropped before `NSURL` parses it, because `.path` decodes it to a NUL on older Foundation and keeps it literal on macOS 26.

## Writing one

`writeM3UForEntries:relativeToDirectory:toURL:error:` is the only writer. It writes `m3uTextForEntries:relativeToDirectory:` atomically as UTF-8 without a BOM. An entry under the target directory is written relative to it, and anything else is absolute. `commonDirectoryForEntries:` answers the folder that makes every entry relative.

**A cue entry is written with two more directives before its path.** VLC's `#EXTVLCOPT:start-time=` and `stop-time=` let other players play the slice. `#VIBE-CUE:` carries the window and the names, which the readers turn back into exactly that entry. The line carries everything rather than pointing at the sheet. An app may restore a playlist on main at launch, where reading a sheet on a cloud placeholder or a dead mount would hang the launch. A malformed line reads as a plain entry.

**TRAP: every M3U reader trims whitespace, splits at newlines, and skips a leading `#`.** So a name any of those would mangle goes out as a percent-encoded `file://` URL, which reads back whole. A backslash in a name does not round-trip, because the Windows-separator rule turns it into `/`.

`entriesInM3UData:` reads the app's own absolute output with no resolution rungs and nothing stat'd. So a mirror an app saved comes back without a probe or a grant panel.

## Tests

`Tests/media/Playlists/` holds Vibe's tests of the readers and the writer: the CUE lexing and windows, the encodings, the rungs, the embedded sheet, the M3U round trips, a fuzz suite, and a stress suite of hostile M3U files. They read and write entries. `VibePlaylistFileTestCase` is their harness of temporary folders, with no tests. The embedded-sheet and fuzz tests write their FLAC headers with `Tests/Support/FLACFixtures.h` and draw from `Tests/Support/VibeFuzzRandom.h`. `VIBE_FUZZ_SEED` re-runs one base seed. The minimal consumer writes an M3U, reads it back, and reads a small CUE sheet.

What Vibe adds stays in Vibe: its rows made from entries and the session mirror, with their tests. The folder walk's claims are `media/FolderScan`'s.
