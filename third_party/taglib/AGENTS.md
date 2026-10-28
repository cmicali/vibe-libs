# third_party/taglib

A subset of [TagLib](https://taglib.org) 2.3.2, `toolkit/taglib.h`'s version. It reads audio metadata. Other authors' code: **do not restyle it.** It depends on nothing. Its template is `VibeLibsTaglib`.

## What is vendored

Only the formats Vibe plays: `mpeg/` and ID3, `mp4/`, `flac/`, `riff/`, and `ogg/` with its `vorbis/` and `opus/` files. It also keeps the APE *tag* machinery that MPEG files need, and `ogg/xiphcomment` for FLAC and Ogg comments. It has no Ogg FLAC, which Vibe refuses. It has nothing for CAF or W64, which TagLib cannot read.

`TagLib::FileRef` is not vendored, since its detection references every format parser. `media/Tags`' `TagLibAudioFile` factory stands in for it. It mirrors FileRef's extension-then-content-sniff detection for these formats. An update re-checks it against `fileref.cpp`.

Four packaging edits:

- `toolkit/tlist.h` carries its `.tcc` file, pasted in where it was included.
- `toolkit/tmap.h` carries its `.tcc` file the same way.
- `toolkit/tstring.cpp` includes `utf8-cpp.checked.h` for `<utf8.h>`.
- `taglib_config.h` defines `TAGLIB_WITH_APE`. Without it, `MPEG::File` compiles its APE reading out (`media/Metadata`'s `testMP3WithAnAPETag`).

## Building

Its files include each other by name. So the template searches every directory that holds its headers. Its sources are C++17, so an app builds C++ as C++17 or later. Its sources build with the static analyzer off and `-Wno-documentation-html`. `LICENSE.MPL` stays out of an app's bundle.

**TRAP: an app that also takes `VibeLibsVorbis` lists it before `VibeLibsTaglib` and before `VibeLibsTags`.** `ogg/vorbis/vorbisfile.h` here is TagLib's own. It answers `<vorbis/vorbisfile.h>` when `taglib/ogg` is searched first, and the first search path wins. An app's search paths follow the order of its templates. `make check-pieces` settles the spelling as libvorbis's.

## Updating

Re-copy the same subset, re-apply the four edits, and let the linker report anything new. 2.3 added the MP4 chapter and STEM files, which `MP4::File` now references. Re-count the files that carry both license notices, below. Then run this repo's `make test`, whose Tags tests detect each format through it. Then run Vibe's `make test-audio`, whose tag tests and fuzz family read every fixture through it.

## License

TagLib is dual-licensed. Each source file offers the GNU Lesser General Public License 2.1 *or* the Mozilla Public License 1.1, at the recipient's choice. **vibe-libs and Vibe use it under the Mozilla Public License 1.1.** Its full text is `LICENSE.MPL`, as MPL 1.1 §3.6 requires. 172 of the 176 source files carry both notices. The other four are `taglib_config.h`, `id3v2.h`, and the two UTF8-CPP headers. `toolkit/utf8-cpp.checked.h` and `utf8-cpp.core.h` are not TagLib's code. They carry a permissive grant in the style of the Boost license, which keeping them unmodified satisfies. `THIRD-PARTY-NOTICES.md` at the repo root has the full notice.
