//
//  OggFixtures.h
//  vibe-libs
//
//  Ogg pages, built by hand, since no Apple encoder writes Ogg.
//  VibeOggPage writes one page of whole packets. VibeOggTagFile is a Vorbis
//  or Opus stream whose audio packets TagLib never decodes, for the tag
//  writer's tests. VibeRepeatedOgg repeats a real stream's audio pages, for
//  a decodable file of any length: Tests/Fuzz's seeds are its sources.
//

#import <Foundation/Foundation.h>

static inline uint32_t VibeOggCRC(const uint8_t *bytes, size_t length) {
    static uint32_t table[256];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t r = i << 24;
            for (int bit = 0; bit < 8; bit++) r = (r & 0x80000000u) ? (r << 1) ^ 0x04C11DB7u : r << 1;
            table[i] = r;
        }
    });
    uint32_t crc = 0;
    for (size_t i = 0; i < length; i++) crc = (crc << 8) ^ table[((crc >> 24) ^ bytes[i]) & 0xFF];
    return crc;
}

// Rewrites a page's sequence number, granule, and flags, then its CRC.
static inline void VibeOggRestamp(NSMutableData *page, uint32_t sequence, int64_t granule, uint8_t flags) {
    uint8_t *b = (uint8_t *)page.mutableBytes;
    b[5] = flags;
    memcpy(b + 6, &granule, 8);
    memcpy(b + 18, &sequence, 4);
    memset(b + 22, 0, 4);
    const uint32_t crc = VibeOggCRC(b, page.length);
    memcpy(b + 22, &crc, 4);
}

// One page holding whole `packets`.
static inline NSData *VibeOggPage(NSArray<NSData *> *packets, uint8_t flags, int64_t granule, uint32_t sequence) {
    NSMutableData *lacing = [NSMutableData data];
    NSMutableData *body = [NSMutableData data];
    for (NSData *packet in packets) {
        NSUInteger left = packet.length;
        while (left >= 255) {
            const uint8_t full = 255;
            [lacing appendBytes:&full length:1];
            left -= 255;
        }
        const uint8_t last = (uint8_t)left;
        [lacing appendBytes:&last length:1];
        [body appendData:packet];
    }
    NSMutableData *page = [NSMutableData dataWithBytes:"OggS\0" length:5];
    [page increaseLengthBy:9];  // flags and granule, stamped below
    const uint32_t serial = 0x56494245;
    [page appendBytes:&serial length:4];
    [page increaseLengthBy:8];
    const uint8_t count = (uint8_t)lacing.length;
    [page appendBytes:&count length:1];
    [page appendData:lacing];
    [page appendData:body];
    VibeOggRestamp(page, sequence, granule, flags);
    return page;
}

static inline NSData *VibeOggBytes(const char *bytes, size_t length) {
    return [NSData dataWithBytes:bytes length:length];
}

// An Ogg Vorbis or Opus stream's headers and five audio pages. The audio
// packets are not decodable. TagLib reads only the headers and granules.
static inline NSData *VibeOggTagFile(BOOL opus) {
    NSMutableData *file = [NSMutableData data];
    if (opus) {
        [file appendData:VibeOggPage(@[VibeOggBytes("OpusHead\x01\x02\x38\x01\x80\xBB\x00\x00\x00\x00\x00", 19)],
                                     0x02, 0, 0)];
        [file appendData:VibeOggPage(@[VibeOggBytes("OpusTags\x04\0\0\0vibe\0\0\0\0", 20)], 0, 0, 1)];
    }
    else {
        [file appendData:VibeOggPage(@[VibeOggBytes("\x01vorbis\0\0\0\0\x02\x44\xAC\0\0\0\0\0\0\0\xF4\x01\0\0\0\0\0\xB8\x01",
                                                    30)], 0x02, 0, 0)];
        [file appendData:VibeOggPage(@[VibeOggBytes("\x03vorbis\x04\0\0\0vibe\0\0\0\0\x01", 20),
                                       VibeOggBytes("\x05vorbis\x00\x42\x43\x56\x01\x00\x00\x00", 15)], 0, 0, 1)];
    }
    for (uint32_t page = 0; page < 5; page++) {
        uint8_t packet[40];
        memset(packet, (int)(0x30 + page), sizeof packet);
        packet[0] = opus ? 0xF8 : 0x00;
        [file appendData:VibeOggPage(@[VibeOggBytes((const char *)packet, sizeof packet)], page == 4 ? 0x04 : 0,
                                     (int64_t)(page + 1) * 960, page + 2)];
    }
    return file;
}

// The pages of an Ogg stream with one logical stream, in order.
static inline NSArray<NSData *> *VibeOggPages(NSData *file) {
    NSMutableArray<NSData *> *pages = [NSMutableArray array];
    const uint8_t *b = (const uint8_t *)file.bytes;
    for (NSUInteger at = 0; at + 27 <= file.length;) {
        if (memcmp(b + at, "OggS", 4) != 0) break;
        const NSUInteger segments = b[at + 26];
        NSUInteger length = 27 + segments;
        for (NSUInteger i = 0; i < segments; i++) length += b[at + 27 + i];
        if (at + length > file.length) break;
        [pages addObject:[file subdataWithRange:NSMakeRange(at, length)]];
        at += length;
    }
    return pages;
}

// `source`'s header pages, then its audio pages, the ones past granule 0,
// `repeats` times, each granule moved on by the source's audio length. The
// last page ends the stream. Opus counts its pre-skip in its granules, so
// the length is the last granule less the pre-skip.
static inline NSData *VibeRepeatedOgg(NSData *source, NSUInteger repeats) {
    NSArray<NSData *> *pages = VibeOggPages(source);
    NSMutableData *file = [NSMutableData data];
    NSMutableArray<NSData *> *audio = [NSMutableArray array];
    uint32_t sequence = 0;
    int64_t preSkip = 0;
    for (NSData *page in pages) {
        int64_t granule;
        memcpy(&granule, (const uint8_t *)page.bytes + 6, 8);
        const uint8_t *body = (const uint8_t *)page.bytes + 27 + ((const uint8_t *)page.bytes)[26];
        if (granule == 0 && audio.count == 0) {
            if (memcmp(body, "OpusHead", 8) == 0) preSkip = body[10] | body[11] << 8;
            [file appendData:page];
            sequence++;
        }
        else {
            [audio addObject:page];
        }
    }
    int64_t last;
    memcpy(&last, (const uint8_t *)audio.lastObject.bytes + 6, 8);
    const int64_t length = last - preSkip;
    for (NSUInteger repeat = 0; repeat < repeats; repeat++) {
        for (NSUInteger i = 0; i < audio.count; i++) {
            NSMutableData *page = [audio[i] mutableCopy];
            int64_t granule;
            memcpy(&granule, (const uint8_t *)page.bytes + 6, 8);
            const BOOL end = repeat + 1 == repeats && i + 1 == audio.count;
            const uint8_t flags = (uint8_t)((((const uint8_t *)page.bytes)[5] & ~0x04) | (end ? 0x04 : 0));
            VibeOggRestamp(page, sequence++, granule + (int64_t)repeat * length, flags);
            [file appendData:page];
        }
    }
    return file;
}
