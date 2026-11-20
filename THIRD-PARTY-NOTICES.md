# Third-party notices

vibe-libs is licensed under Apache 2.0 (see `LICENSE`). Each library under `third_party/` keeps its own license, beside its sources. An app that compiles a piece in carries that piece's notice.

## Summary

| Component | Location | Used under |
| --- | --- | --- |
| TagLib | `third_party/taglib/` | Mozilla Public License 1.1 (see the election below) |
| UTF8-CPP | `third_party/taglib/toolkit/utf8-cpp.*` | Boost-style permissive |
| r8brain-free-src | `third_party/r8brain/` | MIT |
| PFFFT (double) | `third_party/r8brain/fft/` | FFTPACK (BSD-style) |
| dr_mp3 | `third_party/dr_mp3/` | MIT No Attribution (or public domain, at the recipient's choice); modified |
| dr_flac | `third_party/dr_flac/` | MIT No Attribution (or public domain, at the recipient's choice); modified |
| dr_wav | `third_party/dr_wav/` | MIT No Attribution (or public domain, at the recipient's choice); modified |
| libogg | `third_party/ogg/` | BSD 3-Clause |
| libvorbis | `third_party/vorbis/` | BSD 3-Clause |
| Sparkle | `third_party/Sparkle/` | MIT, with its bundled components' permissive notices |
| Monkey's Audio SDK | `third_party/monkeys_audio/` | BSD 3-Clause; modified |
| RSA Data Security MD5 | `third_party/monkeys_audio/MACLib/MD5.*` | RSA's MD5 license (permissive, with attribution) |

## TagLib

TagLib is **dual-licensed**: each source file offers the GNU Lesser General
Public License 2.1 *or* the Mozilla Public License 1.1, at the recipient's
choice. 176 of the 180 vendored source files carry both notices; the remaining
four are `taglib_config.h`, `id3v2.h` (trivial configuration and umbrella
headers with no license block of their own) and the two UTF8-CPP headers,
which are separately licensed and covered below.

**vibe-libs elects the Mozilla Public License 1.1.**

Copyright (C) 2002-2008 Scott Wheeler and the TagLib contributors.
License text: <https://www.mozilla.org/MPL/1.1/>

MPL 1.1 §3.6 requires the license text to accompany the distribution. The full
text is vendored at `third_party/taglib/LICENSE.MPL`.

vibe-libs modifies eleven of TagLib's files, with three edits of its own and seven upstream fixes that no release carries yet. MPL 1.1 §3.3 asks for a record of
the changes and their dates. It is `third_party/taglib/CHANGES.md`, and each
modified file names it at its top.

## UTF8-CPP

`third_party/taglib/toolkit/utf8-cpp.checked.h` and `utf8-cpp.core.h` are
not TagLib's own code and are not covered by TagLib's dual license. They carry
a Boost-Software-License-style permissive grant requiring only that the
copyright notice and license text be retained, which the vendored files do.
Their small changes are listed in `third_party/taglib/CHANGES.md`.

Copyright 2006 Nemanja Trifunovic.

## r8brain-free-src

Sample rate converter designed by Aleksey Vaneev of Voxengo.

Copyright (c) 2013-2026 Aleksey Vaneev. Licensed under the MIT License; the
full text is vendored at `third_party/r8brain/LICENSE.txt` (upstream's `LICENSE`,
renamed so the build leaves it out of the bundles). The author asks for the
credit line above in the documentation of software that uses it.

## PFFFT (double precision)

`third_party/r8brain/fft/pffft_double.*`, `pffft_priv_impl.h` and
`simd/` are the FFT r8brain-free-src runs on here (`R8B_PFFFT_DOUBLE`).

Copyright (c) 2013 Julien Pommier. Copyright (c) 2020 Hayati Ayguen.
Copyright (c) 2020 Dario Mambro. Based on FFTPACKv4 by Paul Swarztrauber,
NCAR, released under the FFTPACKv5 license: redistribution in source and
binary forms is permitted provided the copyright notices, the conditions and
the disclaimer are retained (source) or reproduced in the documentation
(binary), and the names of NCAR, UCAR and their contributors are not used to
endorse the product. The full notice is at the head of
`third_party/r8brain/fft/pffft_double.c`.

## dr_mp3

MPEG audio decoder by David Reid, based on minimp3 by Lion (lieff). Copyright
2023 David Reid. Offered as public domain (the Unlicense) or under the MIT
No Attribution license, at the recipient's choice; vibe-libs uses it under MIT
No Attribution. Both texts are at the end of
`third_party/dr_mp3/dr_mp3.h`. minimp3, the decoder it carries, is CC0.
The vendored copy carries fixes of Vibe's own (`third_party/dr_mp3/AGENTS.md`),
which that license permits without condition.

## dr_flac

FLAC audio decoder by David Reid. Copyright 2023 David Reid. Offered as
public domain (the Unlicense) or under the MIT No Attribution license, at the
recipient's choice; vibe-libs uses it under MIT No Attribution. Both texts are at
the end of `third_party/dr_flac/dr_flac.h`. The vendored copy carries
fixes of Vibe's own (`third_party/dr_flac/AGENTS.md`), which that license permits
without condition.

## dr_wav

WAV and AIFF audio decoder by David Reid. Copyright 2023 David Reid. Offered
as public domain (the Unlicense) or under the MIT No Attribution license, at
the recipient's choice; vibe-libs uses it under MIT No Attribution. Both texts are
at the end of `third_party/dr_wav/dr_wav.h`. The vendored copy carries
fixes and additions of Vibe's own (`third_party/dr_wav/AGENTS.md`), which that
license permits without condition.

## libogg and libvorbis

The Ogg page reader and the Vorbis decoder from the Xiph.Org Foundation.
Copyright (c) 2002 (libogg) and 2002-2020 (libvorbis), Xiph.org Foundation.
Licensed under the BSD 3-Clause license. The full texts are vendored at
`third_party/ogg/LICENSE.txt` and `third_party/vorbis/LICENSE.txt`
(upstream's `COPYING`, renamed so the build leaves them out of the bundles).
Both are unmodified. The license, as libvorbis states it:

```
Copyright (c) 2002-2020 Xiph.org Foundation

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:

- Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.

- Redistributions in binary form must reproduce the above copyright
notice, this list of conditions and the following disclaimer in the
documentation and/or other materials provided with the distribution.

- Neither the name of the Xiph.org Foundation nor the names of its
contributors may be used to endorse or promote products derived from
this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE FOUNDATION
OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## Sparkle

The software update framework, for a macOS app that updates itself. It is
vendored unmodified, as the prebuilt release. Copyright 2006-2013 Andy
Matuschak, 2009-2013 Elgato Systems GmbH, 2011-2014 Kornel Lesiński,
2015-2017 Mayur Pawashe, 2014 C.W. Betts, 2014 Petroules Corporation, and
2014 Big Nerd Ranch. MIT license. It bundles bsdiff 4.3 (Colin Percival, BSD
2-clause), sais-lite (Yuta Mori, MIT), orlp/ed25519 (Orson Peters, zlib), and
`SUSignatureVerifier.m` (Mark Hamlin, BSD 2-clause). Sparkle's license and all
four notices are `third_party/Sparkle/LICENSE.txt`.

## Monkey's Audio SDK

The decoding half of the Monkey's Audio SDK 13.47, by Matthew T. Ashland,
from <https://monkeysaudio.com>. Copyright 2000-2026 Matthew T. Ashland.
Licensed under the BSD 3-Clause license. The full text is vendored at
`third_party/monkeys_audio/LICENSE.txt` (the SDK's `License.txt`). The copy is
modified: `third_party/monkeys_audio/AGENTS.md` lists the changes. The license:

```
Monkey's Audio License Agreement (3 clause BSD)

Copyright 2000-2026 Matthew T. Ashland. All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

1) Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
2) Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
3) Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE REGENTS OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## RSA Data Security, Inc. MD5 Message-Digest Algorithm

The Monkey's Audio SDK's `MD5.cpp` and `MD5.h` are derived from the RSA Data
Security, Inc. MD5 Message-Digest Algorithm. Their notice:

```
Copyright (C) 1991-2, RSA Data Security, Inc. Created 1991. All
rights reserved.

License to copy and use this software is granted provided that it
is identified as the "RSA Data Security, Inc. MD5 Message-Digest
Algorithm" in all material mentioning or referencing this software
or this function.

License is also granted to make and use derivative works provided
that such works are identified as "derived from the RSA Data
Security, Inc. MD5 Message-Digest Algorithm" in all material
mentioning or referencing the derived work.

RSA Data Security, Inc. makes no representations concerning either
the merchantability of this software or the suitability of this
software for any particular purpose. It is provided "as is"
without express or implied warranty of any kind.

These notices must be retained in any copies of any part of this
documentation and/or software.
```
