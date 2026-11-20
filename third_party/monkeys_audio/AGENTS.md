# third_party/monkeys_audio

The decoding half of the [Monkey's Audio](https://monkeysaudio.com) SDK 13.47 (`MAC_1347_SDK.zip`, `Version.h`'s 13.47), by Matthew T. Ashland. It decodes `.ape` files, every compression level from Fast to Insane, and files older than 3.99 through its old decoder. `audio/Decode`'s `AudioFileHandle` reads through it, behind the C surface of `audio/Decode/VibeAPEDecoder.h`. Other authors' code: **do not restyle it.** It depends on nothing. Its template is `VibeLibsMonkeysAudio`.

## What is vendored

`MACLib/` holds the SDK's `Source/MACLib/` decode files, its `Old/` decoder for files older than 3.99, and the `Source/Shared/` files they need, all in one folder. It leaves out the encoder (`APECompress*.cpp` and `BitArray.cpp`), the WAV reader, the console tool, the DLL, the GUI, and everything Windows-only. It keeps the NEON filter, `NNFilterNeon.cpp`, which Apple silicon runs, and the SSE and AVX filters, which compile to nothing on arm64 and to SSE2 alone on x86_64. AltiVec and RISC-V are left out. `APECompress.h`, `BitArray.h`, `MACProgressHelper.h`, and `WAVInputSource.h` are there only because decode files include them.

Three edits. The files keep upstream's CRLF line ends.

- **The folder is flat.** The SDK's `Source/Shared/` and `Source/MACLib/Old/` files sit beside `Source/MACLib/`'s, so every quoted include finds its header beside the file, and no search path is needed.
- So three includes of `"Old/X.h"` lost the `Old/`: in `MACLib.cpp`, `APEDecompressCore.cpp`, and `UnBitArrayBase.cpp`.
- `All.h` comments out `#define APE_SUPPORT_COMPRESS`, the SDK's own switch, so `MACLib.cpp` compiles without the encoder.

## Building

The template adds only `MACLib/*.cpp`, with the dr_ decoders' flags: `-O3` in every configuration, `-w`, and the static analyzer off. Its search path is `third_party/`, so `audio/Decode/VibeAPEDecoder.cpp` includes `"monkeys_audio/MACLib/MACLib.h"`.

**TRAP: none of its headers may join an app's project, and no search path may reach `MACLib/`.** Its `APETag.h` would answer for TagLib's `apetag.h` on a case-insensitive disk, through the headermap or the path. No other name collides today.

**TRAP: only `VibeAPEDecoder.cpp` includes its headers.** They define `BOOL`, `TRUE`, `FALSE`, `CALLBACK`, `MAX_PATH`, and Windows' types, which clash with Objective-C's. The C surface carries plain C types.

**Its global symbols.** Its classes are in `namespace APE`. `MACLib.cpp` also exports C functions with no prefix, among them `CreateIAPEDecompress`, `CreateIAPEIO`, `FillWaveHeader`, `GetAPEFileType`, `VerifyFile`, and `DecompressFile`. An app that links another copy of the SDK collides with them.

## How the decoder runs

- **Each open decoder starts one thread of its own**, at its first read or seek, and joins it when it closes. The caller's thread reads each frame's bytes through the handle (`ScheduleFrameDecode`), and the worker decodes them a frame ahead. So the handle's reads, waits, and interruptions all happen on the caller's thread.
- **A frame is 73,728 audio frames at Fast, Normal, and High, 4 times that at Extra High, and 16 times that at Insane**: 1.7, 6.7, and 26.7 s at 44.1 kHz. A seek decodes from the start of the frame that holds its target, so a seek costs up to one frame's decode. The speeds below give that cost.
- **Each open decoder holds about two frames of PCM and one frame of the file's bytes**: the caller's frame buffer, the worker's, and the worker's input. For 16-bit stereo that is about 0.7 MB at Normal and 12 MB at Insane. A play, its prefetch, and a waveform pass each hold one.
- **The SDK's thread state is plain fields**, such as `m_bExit` and `m_nErrorState`, set on one thread and read on the other. The thread sanitizer reports them. The semaphores order them in practice. They are upstream's.
- **The open reads only the file's head**: any ID3v2 tags, the descriptor, the header, the seek table, and the source WAV's header. `VibeAPEDecoder.cpp` makes the APEv2 tag lazy, so the tag is read only when the last frame is, since the tag's size gives that frame's bytes. The SDK skips its ID3v1 check for a WAV whose trailing chunk is exactly 128 bytes. The lazy tag always checks.

## What it refuses

- **A file newer than 3.99**, the format every SDK since 2004 writes, but for 4.11, which the SDK takes. `VibeAPEDecoderOpen` checks this before the SDK's own factory, since that factory keeps the file's info when it refuses the version.
- **A frame larger than Insane's 1,179,648 audio frames.** The SDK takes up to ten million and sizes its buffers by it.
- **A sample width other than 8, 16, 24, or 32 bits.** 32 bits may be integer or float.
- **Any file whose header the SDK refuses**: no `MAC ` or `MACF` within 1 MB of the start, no frames, over 32 channels, or a final frame longer than a frame.

Files older than 3.99, from 2000 to 2003, decode through `Old/`. No such file was at hand to test.

## Speed

Measured on 2026-11-20 on an M4 Max (12 performance cores), at a load average of 7 to 8, best of five runs. The source is five minutes of 16-bit stereo at 44.1 kHz, pink noise under a few modulated tones, so every level compresses it to 23 MB. FLAC is the same audio at `flac -5`, 22 MB. Each file is decoded to float32, planar, in 4,096-frame reads, as the handle reads it: `VibeAPEDecoder` for APE and the vendored dr_flac for FLAC, both at `-O3`. The seek is the worst case, one whole frame decoded, worked out from the speed.

| Level | Frame | Decode | Times real time | Worst seek |
| --- | --- | --- | --- | --- |
| FLAC (dr_flac) | | 0.06 s | 4,875× | |
| Fast | 1.7 s | 0.49 s | 613× | 3 ms |
| Normal | 1.7 s | 0.60 s | 498× | 3 ms |
| High | 1.7 s | 0.71 s | 422× | 4 ms |
| Extra High | 6.7 s | 1.11 s | 270× | 25 ms |
| Insane | 26.7 s | 3.37 s | 89× | 300 ms |

The wall time equals the CPU time: the worker decodes while the caller waits, so one decode uses one core.

- **Every level is far faster than playback needs.** Even Insane decodes a second of audio in 11 ms.
- **The whole-file passes feel it.** The waveform and the analysis read a whole file. A one-hour mix takes about 7 s at Normal and 40 s at Insane, against under 1 s for FLAC.
- **Insane's seek is the one cost a listener can notice.** A seek decodes from the start of its 26.7 s frame, up to 0.3 s. Extra High's 25 ms is not noticed.
- **Nothing is special-cased yet.** The SDK can decode frames on more threads (`SetNumberOfThreads`), which would speed the whole-file passes at the cost of more cores. The handle uses one.

## Making test files

The SDK's own `mac` tool encodes. Build it from the full SDK, not from this copy, with Xcode's clang:

```
xcrun clang++ -std=c++11 -O2 -DPLATFORM_APPLE -w -I Source/MACLib -I Source/Shared Source/Console/Console.cpp \
    Source/MACLib/*.cpp Source/MACLib/Old/*.cpp Source/MACDll/MACDll.cpp Source/Shared/{BufferIO,CharacterHelper,CircleBuffer,CPUFeatures,CRC,GlobalFunctions,MemoryIO,Semaphore,Thread,WholeFileIO,StdLibFileIO}.cpp -o mac
```

`Tests/audio/Decode/make-ape-fixtures.py` and `Tests/Fuzz/make-seeds.sh` take its path.

## Updating

Copy the same files from the new SDK, flatten them into `MACLib/` again, and re-apply the four edits. Let the linker report anything new. Diff `MACLib.cpp`'s `CreateIAPEDecompressCore` against `VibeAPEDecoderOpen`'s version check. Then run this repo's `make test`, whose `AudioFileHandleAPETests` decode every level and width bit for bit, and whose `AudioFileHandleFuzzAPETests` and streaming tests read the fixtures through it.

## License

BSD 3-Clause, in `LICENSE.txt` (the SDK's `License.txt`). Copyright 2000-2026 Matthew T. Ashland. `MD5.cpp` and `MD5.h` are derived from the RSA Data Security, Inc. MD5 Message-Digest Algorithm, under RSA's notice in those files. `THIRD-PARTY-NOTICES.md` at the repo root has both texts.
