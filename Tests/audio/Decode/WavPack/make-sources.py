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


def dsf(path, samples, rate=2822400, channel_type=2, lsb_first=True):
    """A DSD file of a 1 kHz sine at half scale, a different phase in each
    channel, by a second-order delta-sigma modulator: DSD64 stereo by
    default, `samples` a channel. The DSF fixtures beside this script are
    these files, so a test can decode the same DSD from a DSF and a .wv."""
    block = 4096
    count = {1: 1, 2: 2, 7: 6}[channel_type]
    channels = []
    for c in range(count):
        out = bytearray((samples + 7) // 8)
        i1 = i2 = 0.0
        y = 0.0
        for n in range(samples):
            x = 0.5 * math.sin(2 * math.pi * 1000 * n / rate + c)
            i1 += x - y
            i2 += i1 - y
            y = 1.0 if i2 >= 0 else -1.0
            if y > 0:
                out[n >> 3] |= (1 << (n & 7)) if lsb_first else (0x80 >> (n & 7))
        out += b'\x00' * (-len(out) % block)  # zeros pad the last block, as the format asks
        channels.append(out)
    data = bytearray()
    for b in range(0, len(channels[0]), block):
        for c in channels:
            data += c[b:b + block]
    fmt = struct.pack('<4sQIIIIIIQII', b'fmt ', 52, 1, 0, channel_type, count, rate, 1 if lsb_first else 8,
                      samples, block, 0)
    data_chunk = b'data' + struct.pack('<Q', 12 + len(data)) + data
    total = 28 + len(fmt) + len(data_chunk)
    head = b'DSD ' + struct.pack('<QQQ', 28, total, 0)
    Path(path).write_bytes(head + fmt + data_chunk)


def wavpack_blocks(data):
    """Each block's offset and length: "wvpk", then its size after these 8 bytes."""
    at = 0
    while at + 32 <= len(data) and data[at:at + 4] == b'wvpk':
        size = struct.unpack_from('<I', data, at + 4)[0] + 8
        yield at, size
        at += size


def resum(data, at, length):
    """Writes a block's checksum again, as AudioFileFixtures.h's VibeWavPackResum does."""
    block = memoryview(data)[at:at + length]
    sub = 32
    while sub + 2 <= length:
        ident = block[sub]
        header = 4 if ident & 0x80 else 2
        size = block[sub + 1] * 2 + ((block[sub + 2] << 9) + (block[sub + 3] << 17) if ident & 0x80 else 0)
        if ident & 0x3F == 0x2F:
            total = 0xFFFFFFFF
            for w in range(0, sub, 2):
                total = (total * 3 + block[w] + (block[w + 1] << 8)) & 0xFFFFFFFF
            if size == 2:
                total ^= total >> 16
                struct.pack_into('<H', block, sub + header, total & 0xFFFF)
            else:
                struct.pack_into('<I', block, sub + header, total)
        sub += header + size


def damaged(source, out, how):
    """A copy of a DSD .wv, damaged as `how` names. "no-qmode" clears the
    source's bit order from every block's new config, so the file is told as
    DSD by its blocks' DSD flag alone. "hybrid" sets the first block's hybrid
    flag, which WavPack's encoder never writes for DSD."""
    data = bytearray(Path(source).read_bytes())
    for at, length in wavpack_blocks(data):
        if how == 'hybrid':
            data[at + 24] |= 0x08
            resum(data, at, length)
            break
        sub = at + 32
        while sub + 2 <= at + length:
            ident = data[sub]
            header = 4 if ident & 0x80 else 2
            size = data[sub + 1] * 2 + ((data[sub + 2] << 9) + (data[sub + 3] << 17) if ident & 0x80 else 0)
            if ident & 0x3F == 0x2A and size >= 2:
                data[sub + header + 1] = 0
            sub += header + size
        resum(data, at, length)
    Path(out).write_bytes(bytes(data))


def png(path):
    """A 4 by 4 grey square, for an APE tag's cover."""
    def chunk(kind, body):
        return struct.pack('>I', len(body)) + kind + body + struct.pack('>I', zlib.crc32(kind + body))
    rows = b''.join(b'\x00' + bytes([0x80] * 4) for _ in range(4))
    Path(path).write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 4, 4, 8, 0, 0, 0, 0))
                           + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))


def main():
    if sys.argv[1] == '--damage':
        damaged(sys.argv[3], sys.argv[4], sys.argv[2])
        return
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
    dsf(out / 'dsd.dsf', 141120)
    dsf(out / 'dsd-msb.dsf', 141120, lsb_first=False)
    dsf(out / 'dsd128-48k.dsf', 122880, rate=6144000, channel_type=1)
    dsf(out / 'dsd256.dsf', 56448, rate=11289600)
    dsf(out / 'dsd512.dsf', 90112, rate=22579200)
    dsf(out / 'dsd-surround.dsf', 45056, channel_type=7)
    dsf(out / 'dsd-odd.dsf', 141123)


if __name__ == '__main__':
    main()
