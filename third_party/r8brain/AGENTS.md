# third_party/r8brain

[r8brain-free-src](https://github.com/avaneev/r8brain-free-src), upstream commit `9e73d2dd`, Aleksey Vaneev's sample rate converter. `audio/DSP`'s resampler wraps it (`AudioResampler.mm`), and `audio/Player`'s voice bus resamples with that. Other authors' code: **do not restyle it.** It depends on nothing. Its template is `VibeLibsR8brain`.

## Building

It is header-only apart from two files: `DLL/r8bsrc.cpp`, upstream's C entry points, where every template is instantiated, and `fft/pffft_double.c`. Apps include `"r8brain/DLL/r8bsrc.h"`, so the template searches `third_party/` itself. The template builds both files with:

- `-O3` in every configuration. At `-O0` it would cost many times its optimized self, and a Debug build is where an app's quality and cost tests run.
- `-DR8BSRC_DECL=`, upstream's switch from a DLL to an object file. An app defines `R8BSRC_DECL` empty before it includes `r8bsrc.h`.
- `R8B_PFFFT_DOUBLE`, the README's speed setting: double-precision PFFFT at Ooura's accuracy. Its other, `R8B_EXTFFT`, costs more than it saves at the 1% transition band Vibe uses, so it is off (Vibe's `docs/audio-quality.md`).
- `PFFFT_ENABLE_NEON`.
- `-w`, which silences the vendored C's warnings, and the static analyzer off.

**TRAP: PFFFT's NEON path is opt-in, and `-w` hides the `#pragma message` that says so.** Without the macro, arm64 silently uses the scalar fallback. x86_64 selects SSE2 by itself. Check with `clang -arch arm64 -fsyntax-only fft/pffft_double.c` plus the flags, which prints the backend chosen.

Every file that includes an r8brain header must see the same `R8B_*` macros. So nothing but `r8bsrc.cpp` includes them.

`LICENSE.txt` is upstream's `LICENSE`. It and the `.inc` filter tables stay out of an app's bundle.

## What is vendored

Only what those two files compile, checked with `clang -H` for arm64 and x86_64. Not upstream's `r8butil.h`, the single-precision `pffft.c`, the Ooura `fft4g.h` (unused under `R8B_PFFFT_DOUBLE`), the Windows DLL builds, `bench/`, or `other/`. When updating, re-copy the same set and re-run that check.

## License

MIT, in `LICENSE.txt`. Copyright (c) 2013-2026 Aleksey Vaneev. The author asks for the credit line "Sample rate converter designed by Aleksey Vaneev of Voxengo" in the documentation of software that uses it. The FFT in `fft/` is PFFFT, under the FFTPACKv5 license. Its notice is at the head of `fft/pffft_double.c`. `THIRD-PARTY-NOTICES.md` at the repo root has both.
