#!/usr/bin/env python3 -I
"""Writes the Monkey's Audio fixtures in Tests/audio/Decode/APE.

Each is the signal APEFixtureSample() in AudioFileHandleAPETests.m computes,
a triangle and a little hashed noise, made with integer math only, so the
tests rebuild every sample and compare the decode bit for bit. None is anyone's
recording. The SDK's own `mac` encoder compresses each source: build it from
the SDK (third_party/monkeys_audio/AGENTS.md says how) and pass its path.

    python3 -I Tests/audio/Decode/make-ape-fixtures.py /path/to/mac

Re-run it only to change the fixtures, then commit them.
"""

import os
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "APE")


def sample16(n, c):
    """The 16-bit signal at frame n of channel c, in [-8194, 8192]."""
    phase = (n * (300 + 97 * c)) & 0xFFFF
    tri = phase if phase < 32768 else 65535 - phase
    h = (n * 2654435761 + c * 40503) & 0xFFFFFFFF
    return (tri >> 1) - 8192 + ((h >> 16) & 3) - 2


def frames_bytes(frames, channels, depth, big_endian=False):
    """Interleaved samples at the depth: 8 (unsigned), 16, 24, 32, or 'float'."""
    out = bytearray()
    order = ">" if big_endian else "<"
    for n in range(frames):
        for c in range(channels):
            s = sample16(n, c)
            if depth == 8:
                out.append((s >> 7) + 128)
            elif depth == 16:
                out += struct.pack(order + "h", s)
            elif depth == 24:
                out += struct.pack(">i", s << 8)[1:] if big_endian else struct.pack("<i", s << 8)[:3]
            elif depth == 32:
                out += struct.pack(order + "i", s << 16)
            else:
                out += struct.pack(order + "f", s / 32768.0)
    return bytes(out)


def write_wav(path, rate, channels, depth, frames, mask=0):
    data = frames_bytes(frames, channels, depth)
    bits = 32 if depth == "float" else depth
    align = channels * bits // 8
    tag = 3 if depth == "float" else 1
    if mask:
        fmt = struct.pack("<HHIIHHHHI16s", 0xFFFE, channels, rate, rate * align, align, bits, 22, bits, mask,
                          struct.pack("<H", tag) + b"\x00\x00\x00\x00\x10\x00\x80\x00\x00\xaa\x00\x38\x9b\x71")
    else:
        fmt = struct.pack("<HHIIHH", tag, channels, rate, rate * align, align, bits)
    body = b"WAVE" + b"fmt " + struct.pack("<I", len(fmt)) + fmt + b"data" + struct.pack("<I", len(data)) + data
    with open(path, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", len(body)) + body)


def extended80(value):
    """An AIFF's 80-bit rate, for a whole number."""
    exponent = value.bit_length() - 1
    mantissa = value << (63 - exponent)
    return struct.pack(">HQ", 16383 + exponent, mantissa)


def write_aiff(path, rate, channels, frames):
    data = frames_bytes(frames, channels, 16, big_endian=True)
    comm = struct.pack(">hIh", channels, frames, 16) + extended80(rate)
    ssnd = struct.pack(">II", 0, 0) + data
    body = b"AIFF" + b"COMM" + struct.pack(">I", len(comm)) + comm + b"SSND" + struct.pack(">I", len(ssnd)) + ssnd
    with open(path, "wb") as f:
        f.write(b"FORM" + struct.pack(">I", len(body)) + body)


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    mac = sys.argv[1]
    os.makedirs(OUT, exist_ok=True)
    work = tempfile.mkdtemp()

    def compress(source, name, level, tag=None):
        args = [mac, source, os.path.join(OUT, name), f"-c{level}"]
        if tag:
            args += ["-t", tag]
        subprocess.run(args, check=True, stdout=subprocess.DEVNULL)

    def wav(name, rate, channels, depth, frames, mask=0):
        path = os.path.join(work, name)
        write_wav(path, rate, channels, depth, frames, mask)
        return path

    # Each level, 16-bit stereo at 44.1 kHz, a quarter of a second.
    stereo = wav("stereo.wav", 44100, 2, 16, 11025)
    for level, name in [(1000, "fast"), (2000, "normal"), (3000, "high"), (4000, "extrahigh"), (5000, "insane")]:
        compress(stereo, f"level-{name}.ape", level)
    # Three and a half of Normal's frames of 73,728, mono, for the seeks and
    # the CUE sheet.
    compress(wav("long.wav", 44100, 1, 16, 258048), "long.ape", 2000)
    # Each depth, mono at 48 kHz, a tenth of a second.
    for depth, name in [(8, "depth8"), (24, "depth24"), (32, "depth32"), ("float", "float32")]:
        compress(wav(f"{name}.wav", 48000, 1, depth, 4800), f"{name}.ape", 2000)
    # 5.1, which keeps its WAVE channel mask.
    compress(wav("surround.wav", 48000, 6, 16, 4800, mask=0x3F), "surround51.ape", 2000)
    # An AIFF's big-endian samples.
    aiff = os.path.join(work, "aiff.aiff")
    write_aiff(aiff, 44100, 1, 4410)
    compress(aiff, "aiff16.ape", 2000)
    # An APEv2 tag at the end, and an ID3v2 tag before the descriptor.
    mono = wav("mono.wav", 44100, 1, 16, 4410)
    compress(mono, "tagged.ape", 2000, "Artist=Seed Artist|Album=Seed Album|Title=Seed Title|Track=3|Year=2026")
    with open(os.path.join(OUT, "tagged.ape"), "rb") as f:
        tagged = f.read()
    id3 = b"ID3\x04\x00\x00\x00\x00\x00\x0a" + b"\x00" * 10
    with open(os.path.join(OUT, "id3v2-before.ape"), "wb") as f:
        f.write(id3 + tagged)
    for name in sorted(os.listdir(OUT)):
        print(f"{os.path.getsize(os.path.join(OUT, name)):8d}  {name}")


if __name__ == "__main__":
    main()
