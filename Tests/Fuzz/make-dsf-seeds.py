"""Writes the DSF seeds into Tests/Fuzz/Seeds/tags-dsf, which make-seeds.sh calls.

No encoder on the machine writes DSF, so this modulates a sine itself, with a
second-order delta-sigma modulator, into one 4096-byte block a channel. Run it
as `python3 -I Tests/Fuzz/make-dsf-seeds.py <seeds> <cover.jpg>`.
"""

import math
import pathlib
import struct
import sys


def modulate(frequency, rate, samples):
    out = bytearray((samples + 7) // 8)
    first = second = 0.0
    y = 1.0
    for i in range(samples):
        x = 0.5 * math.sin(2 * math.pi * frequency * i / rate)
        first += x - y
        second += first - y
        y = 1.0 if second >= 0 else -1.0
        if y > 0:
            out[i // 8] |= 0x80 >> (i % 8)
    return out


def reverse(byte):
    return int(f"{byte:08b}"[::-1], 2)


def id3(frames):
    body = b""
    for name, payload in frames:
        body += name + struct.pack(">I", len(payload)) + b"\0\0" + payload
    size = len(body)
    syncsafe = bytes([(size >> 21) & 0x7F, (size >> 14) & 0x7F, (size >> 7) & 0x7F, size & 0x7F])
    return b"ID3\x03\x00\x00" + syncsafe + body


def dsf(channel_type, channels, lsb_first, tag=b""):
    rate, block = 2822400, 4096
    samples = block * 8 - 3  # one block a channel, its last byte padded
    data = bytearray()
    for c in range(channels):
        plane = modulate(440 * (c + 1), rate, samples)
        if lsb_first:
            plane = bytearray(reverse(b) for b in plane)
        data += plane + bytes(block - len(plane))
    end = 92 + len(data)
    header = b"DSD " + struct.pack("<QQQ", 28, end + len(tag), end if tag else 0)
    header += b"fmt " + struct.pack("<QIIIIIIQII", 52, 1, 0, channel_type, channels, rate, 1 if lsb_first else 8,
                                    samples, block, 0)
    header += b"data" + struct.pack("<Q", 12 + len(data))
    return header + bytes(data) + tag


def main():
    seeds = pathlib.Path(sys.argv[1]) / "tags-dsf"
    cover = pathlib.Path(sys.argv[2]).read_bytes()
    seeds.mkdir(parents=True, exist_ok=True)
    text = lambda value: b"\0" + value.encode("latin-1")
    tag = id3([(b"TIT2", text("Fuzz Tone")), (b"TPE1", text("Seed Artist")), (b"TALB", text("Seed Album")),
               (b"TRCK", text("3/9")), (b"TBPM", text("120")), (b"TKEY", text("8A")),
               (b"APIC", b"\0image/jpeg\0\x03\0" + cover)])
    (seeds / "plain.dsf").write_bytes(dsf(2, 2, True))
    (seeds / "tagged.dsf").write_bytes(dsf(2, 2, True, tag))
    (seeds / "msb-mono.dsf").write_bytes(dsf(1, 1, False, tag))
    (seeds / "surround.dsf").write_bytes(dsf(7, 6, True))


if __name__ == "__main__":
    main()
