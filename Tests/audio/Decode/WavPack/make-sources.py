#!/usr/bin/env python3
# Writes the WAV and DSF sources of the WavPack fixtures into the folder given.
# Every sample is integer math on a triangle and a linear congruential noise,
# so AudioFileHandleWavPackTests.m computes the same samples (VibeWavPackSample)
# and no fixture is anyone's recording. make-fixtures.sh encodes them.

import math
import struct
import sys
import zlib
from pathlib import Path


def sample(frame_major_index, frame, channel, bits):
    """The value at one frame and channel, `bits` wide, signed."""
    state = (frame_major_index * 2654435761 + 12345) & 0xFFFFFFFF
    state = (state * 1664525 + 1013904223) & 0xFFFFFFFF
    noise = (state >> 16) - 32768
    full = 1 << (bits - 1)
    amplitude = full >> 1
    period = 200 + 37 * channel
    p = frame % period
    half = period // 2
    if p < half:
        tri = -amplitude + (4 * amplitude * p) // period
    else:
        tri = 3 * amplitude - (4 * amplitude * p) // period
    return tri + ((noise << (bits - 1)) >> 19)


def samples(frames, channels, bits):
    for f in range(frames):
        for c in range(channels):
            yield sample(f * channels + c, f, c, bits)


def wav(path, rate, channels, frames, bits, container=None, float32=False, mask=None, negated=False, silent_tail=0):
    """`negated` writes every sample's negative: another song of the same shape.
    `silent_tail` frames at the end are digital silence."""
    container = container or bits
    width = container // 8
    data = bytearray()
    for i, v in enumerate(samples(frames, channels, bits)):
        v = -v if negated else v
        v = 0 if i >= (frames - silent_tail) * channels else v
        if float32:
            data += struct.pack('<f', v / float(1 << 23))
        elif container == 8:
            data += struct.pack('<B', v + 128)
        else:
            v <<= container - bits
            data += (v & ((1 << container) - 1)).to_bytes(width, 'little')
    tag = 3 if float32 else 1
    if mask is not None or (container != bits and not float32):
        sub = (b'\x03\x00' if float32 else b'\x01\x00') + b'\x00\x00\x00\x00\x10\x00\x80\x00\x00\xaa\x00\x38\x9b\x71'
        fmt = struct.pack('<HHIIHHHHI', 0xFFFE, channels, rate, rate * channels * width, channels * width,
                          container, 22, bits, mask or 0) + sub
    else:
        fmt = struct.pack('<HHIIHH', tag, channels, rate, rate * channels * width, channels * width, container)
    body = b'WAVE' + b'fmt ' + struct.pack('<I', len(fmt)) + fmt + b'data' + struct.pack('<I', len(data)) + data
    Path(path).write_bytes(b'RIFF' + struct.pack('<I', len(body)) + body)


def dsf(path, seconds, rate=2822400):
    """A stereo DSD file, DSD64 by default, of a 1 kHz sine at half scale, a
    different phase in each channel, by a second-order delta-sigma modulator."""
    block = 4096
    bits = int(rate * seconds)
    channels = []
    for c in range(2):
        out = bytearray((bits + 7) // 8)
        i1 = i2 = 0.0
        y = 0.0
        for n in range(bits):
            x = 0.5 * math.sin(2 * math.pi * 1000 * n / rate + c)
            i1 += x - y
            i2 += i1 - y
            y = 1.0 if i2 >= 0 else -1.0
            if y > 0:
                out[n >> 3] |= 1 << (n & 7)  # LSB first
        out += b'\x00' * (-len(out) % block)  # zeros pad the last block, as the format asks
        channels.append(out)
    data = bytearray()
    for b in range(0, len(channels[0]), block):
        for c in channels:
            data += c[b:b + block]
    fmt = struct.pack('<4sQIIIIIIQII', b'fmt ', 52, 1, 0, 2, 2, rate, 1, bits, block, 0)
    data_chunk = b'data' + struct.pack('<Q', 12 + len(data)) + data
    total = 28 + len(fmt) + len(data_chunk)
    head = b'DSD ' + struct.pack('<QQQ', 28, total, 0)
    Path(path).write_bytes(head + fmt + data_chunk)


def png(path):
    """A 4 by 4 grey square, for an APE tag's cover."""
    def chunk(kind, body):
        return struct.pack('>I', len(body)) + kind + body + struct.pack('>I', zlib.crc32(kind + body))
    rows = b''.join(b'\x00' + bytes([0x80] * 4) for _ in range(4))
    Path(path).write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 4, 4, 8, 0, 0, 0, 0))
                           + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))


def main():
    out = Path(sys.argv[1])
    png(out / 'cover.png')
    wav(out / 's16.wav', 44100, 2, 8192, 16)
    wav(out / 's24.wav', 96000, 2, 16384, 24)
    wav(out / 's20.wav', 48000, 2, 4096, 20, container=24)
    wav(out / 's32.wav', 48000, 2, 4096, 32)
    wav(out / 'f32.wav', 44100, 2, 4096, 24, container=32, float32=True)
    wav(out / 'u8.wav', 22050, 1, 4096, 8)
    wav(out / 'surround.wav', 48000, 6, 4096, 16, mask=0x3F)
    wav(out / 'negated.wav', 44100, 2, 8192, 16, negated=True)
    wav(out / 'long.wav', 44100, 2, 640000, 16)
    wav(out / 'fade.wav', 44100, 2, 8192, 16, silent_tail=2048)
    dsf(out / 'dsd.dsf', 0.05)
    dsf(out / 'dsd256.dsf', 0.005, rate=11289600)


if __name__ == '__main__':
    main()
