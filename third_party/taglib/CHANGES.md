# Changes to TagLib

This is the dated record of every change made to the TagLib files vendored here. Mozilla Public License 1.1 §3.3 asks for it, since vibe-libs uses TagLib under that license. Any later change to a file in this directory adds a dated line here.

## Upstream

- **Version:** TagLib 2.3.2, as `toolkit/taglib.h` says.
- **Source:** the `taglib/` directory of tag `v2.3.2` of <https://github.com/taglib/taglib>, commit `deadc2990767dfbda0701e0ab35fdeea653db08f`.
- **Subset:** only the files `AGENTS.md` lists. Every other upstream file is left out, unchanged.
- **Cherry-picks:** seven later upstream commits, which no release carried on 2026-11-17. Each is a dated row below that names its commit. A release that carries them replaces them.

On 2026-11-11, every vendored file was compared byte for byte with that tag. Each of TagLib's own files matches, except the three listed below. The files added around TagLib, also listed below, have no upstream copy in that directory.

## History

TagLib reached Vibe through the owner's CocoaPods packaging, <https://github.com/cmicali/taglib-pod>. Its first edits were made there. Commits of that repository are marked "taglib-pod" below.

Vibe moved TagLib 2.1.0 in-tree on 2026-07-13 (this repo's `19912617`). Vibe's history for the folder came here with it, and it starts at that commit. The import matched tag `v2.1` byte for byte, except the same edits.

On 2026-10-03, `5341fe88` replaced the files with 2.3.2's and re-applied the same edits. Its commit message names the release. It does not name an upstream commit. The byte-for-byte match above ties the files to tag `v2.3.2`.

On 2026-11-20, the subset gained `wavpack/`'s four files from the same tag, unchanged, for WavPack's tags and properties. Upstream's later fixes to them, `f4117f8` and `cf86f20` among them, are already in that tag.

## Changes to TagLib's own files

| Date | Files | Change |
| --- | --- | --- |
| 2025-06-08 | `toolkit/tlist.h` | `tlist.tcc` is pasted in where it was included, and the include is left as a comment. So the build needs no `.tcc` file. The pasted code is unchanged (taglib-pod `7358764`). |
| 2025-06-08 | `toolkit/tmap.h` | `tmap.tcc` is pasted in the same way, for the same reason (taglib-pod `7358764`). |
| 2025-06-08 | `toolkit/tstring.cpp` | `#include <utf8.h>` became `#include "utf8-cpp.checked.h"`, the renamed UTF8-CPP header beside it. Upstream finds `<utf8.h>` in a submodule, which this copy does not carry (taglib-pod `7358764`). The same edit was first made to TagLib 1.12 on 2021-08-22 (taglib-pod `d14a312`). |
| 2026-10-03 | the three files above | The update to 2.3.2 re-applied all three edits unchanged (`5341fe88`). |
| 2026-11-11 | the three files above | Each gained a one-line comment above its license header that points to this record. |
| 2026-11-17 | `riff/wav/infotag.cpp` | Upstream `f9efbc7` (TagLib #1454), not yet released. An INFO chunk header cut short by the tag's end no longer makes a field. Its size check wrapped below zero, so up to 7 trailing bytes read as an empty field. |
| 2026-11-17 | `mpeg/id3v2/id3v2framefactory.cpp` | Upstream `62db511` (TagLib #1457), not yet released. A genre's `(n)` codes are read without copying the rest of the string for each, and at most 50,000 are read. A frame of 100,000 codes took about 100 s to parse, and now takes 0.03 s. |
| 2026-11-17 | `ape/apeitem.cpp`, `mpeg/id3v2/frames/textidentificationframe.cpp` | Upstream `5bd11b2` (TagLib #1458), not yet released. An ID3v2 text frame or an APE text item with more values than 50,000, or one per 32 bytes when that is more than 1,024, is refused. A 1 MB frame of 500,000 values held 186 MB, and now holds 6 MB. |
| 2026-11-17 | `mpeg/id3v2/id3v2tag.cpp` | Upstream `40503eb` (TagLib #1483), not yet released. A frame with an invalid ID is skipped when a valid frame follows it, instead of ending the tag. Before, every later frame was lost, often the picture. |
| 2026-11-17 | `toolkit/tbytevector.cpp`, `toolkit/tbytevector.h` | Upstream `629b707` (TagLib #1484), not yet released. `ByteVector::fromBase64` skips whitespace, so a line-wrapped `METADATA_BLOCK_PICTURE` in a Vorbis or Opus comment decodes. Before, it decoded to nothing and the art was missing. |
| 2026-11-17 | `flac/flacpicture.cpp`, `toolkit/tbytevector.cpp` | Upstream `8fe8b82` (TagLib #1492), not yet released. A FLAC picture's length checks no longer wrap, so a huge MIME type length is refused. Before, it read a picture of garbage. `toNumber` no longer overflows its offset either. |
| 2026-11-17 | `toolkit/tbytevector.cpp` | Upstream `58499cb` (TagLib #1493), not yet released. `ByteVector::containsAt` and `endsWith` check their bounds without wrapping. `containsAt` with an offset near 2^32 read out of bounds and crashed. |
| 2026-11-20 | `ape/apefile.cpp`, `ape/apefile.h`, `ape/apeproperties.cpp`, `ape/apeproperties.h` | Joined the subset from tag `v2.3.2`, unchanged, so Monkey's Audio files are read. Nothing else changed. |

## Files added around TagLib

These are not TagLib's own source. They stand in for what TagLib's CMake build provides.

| Date | Files | Change |
| --- | --- | --- |
| 2019-12-18 | `taglib_config.h` | Stands in for the header CMake generates from `taglib_config.h.cmake`. Its text follows TagLib 1.x's generated header. It defined `TAGLIB_WITH_ASF` and `TAGLIB_WITH_MP4` (taglib-pod `166c389`, `e01a850`). |
| 2021-08-22 | `taglib_config.h` | Gained an include guard and lost a `-Wconversion` pragma (taglib-pod `e32fbc2`). |
| 2025-06-09 | `taglib_config.h` | Defines `TAGLIB_WITH_RIFF` and `TAGLIB_WITH_VORBIS` (taglib-pod `5481f19`). |
| 2026-10-15 | `taglib_config.h` | Defines `TAGLIB_WITH_APE`. Without it, `MPEG::File` compiles its APE tag reading out (`3790f0e8`). |
| 2021-08-22 | `toolkit/utf8-cpp.checked.h`, `toolkit/utf8-cpp.core.h` | UTF8-CPP 2.3.5's `checked.h` and `core.h` from <https://github.com/nemtrif/utfcpp>, which upstream TagLib takes as a submodule. They were renamed with a `utf8-cpp.` prefix, and `checked.h` includes `core.h` by its new name (taglib-pod `d14a312`). |
| 2025-06-08 | `toolkit/utf8-cpp.core.h` | Trailing whitespace was removed. Nothing else changed (taglib-pod `7358764`). |
| 2026-07-08 | `toolkit/utf8-cpp.checked.h` | Its iterator declares its five member types instead of deriving from `std::iterator`, which C++17 deprecates (taglib-pod `1171272`). |
| 2026-08-08 | `LICENSE.MPL` | The Mozilla Public License 1.1's text, as its §3.6 requires (`5066dbe5`). |
| 2026-11-11 | `taglib_config.h`, both UTF8-CPP headers | Each gained a one-line comment that points to this record. |

UTF8-CPP is not under TagLib's license. Its own permissive license asks only that its notice stay, and it does. Its changes are recorded here anyway, so the whole directory has one record.

## What could not be determined

- The taglib-pod dates are its commits' dates. An edit may have been made in a working copy shortly before it was committed.
- A nearby upstream commit with the same files as tag `v2.3.2` would match as well. The tag is the release the update names.
- UTF8-CPP 2.3.6's `checked.h` and `core.h` are identical to 2.3.5's. So the copy may have come from either release.
