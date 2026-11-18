//
//  VibeTagWriterTests.mm
//  vibe-libs
//
//  VibeTagWriter's in-place write over the real TagLib, in every format it
//  writes: each field and the cover round trip, a write leaves what it does
//  not name, and a failed write leaves the file's bytes. The tests write
//  their own files: AVFoundation's encoders, an MP3's frames, and Ogg pages
//  built here, since no Apple encoder writes Ogg.
//

#import <XCTest/XCTest.h>
#import <AVFoundation/AVFoundation.h>
#include <sys/stat.h>

#import "TagLibAudioFile.h"
#import "VibeTagWriter.h"

#include <aifffile.h>
#include <attachedpictureframe.h>
#include <flacfile.h>
#include <flacpicture.h>
#include <id3v1tag.h>
#include <id3v2tag.h>
#include <infotag.h>
#include <mp4file.h>
#include <mpegfile.h>
#include <opusfile.h>
#include <privateframe.h>
#include <tpropertymap.h>
#include <vorbisfile.h>
#include <wavfile.h>
#include <xiphcomment.h>

@interface VibeTagWriterTests : XCTestCase
@end

#pragma mark - Ogg pages

static uint32_t VibeOggCRC(const uint8_t *bytes, size_t length) {
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

// One page holding whole `packets`, each under 255 bytes times 255.
static NSData *VibeOggPage(NSArray<NSData *> *packets, uint8_t flags, int64_t granule, uint32_t sequence) {
    NSMutableData *lacing = [NSMutableData data];
    NSMutableData *body = [NSMutableData data];
    for (NSData *packet in packets) {
        NSUInteger left = packet.length;
        while (left >= 255) {
            uint8_t full = 255;
            [lacing appendBytes:&full length:1];
            left -= 255;
        }
        uint8_t last = (uint8_t)left;
        [lacing appendBytes:&last length:1];
        [body appendData:packet];
    }
    NSMutableData *page = [NSMutableData dataWithBytes:"OggS\0" length:5];
    [page appendBytes:&flags length:1];
    [page appendBytes:&granule length:8];
    const uint32_t serial = 0x56494245;
    [page appendBytes:&serial length:4];
    [page appendBytes:&sequence length:4];
    const uint32_t zero = 0;
    [page appendBytes:&zero length:4];
    const uint8_t count = (uint8_t)lacing.length;
    [page appendBytes:&count length:1];
    [page appendData:lacing];
    [page appendData:body];
    const uint32_t crc = VibeOggCRC((const uint8_t *)page.bytes, page.length);
    memcpy((uint8_t *)page.mutableBytes + 22, &crc, 4);
    return page;
}

static NSData *VibeBytes(const char *bytes, size_t length) {
    return [NSData dataWithBytes:bytes length:length];
}

// An Ogg Vorbis or Opus stream's headers and five audio pages. The audio
// packets are not decodable. TagLib reads only the headers and granules.
static NSData *VibeOggFile(BOOL opus) {
    NSMutableData *file = [NSMutableData data];
    if (opus) {
        [file appendData:VibeOggPage(@[VibeBytes("OpusHead\x01\x02\x38\x01\x80\xBB\x00\x00\x00\x00\x00", 19)],
                                     0x02, 0, 0)];
        [file appendData:VibeOggPage(@[VibeBytes("OpusTags\x04\0\0\0vibe\0\0\0\0", 20)], 0, 0, 1)];
    }
    else {
        [file appendData:VibeOggPage(@[VibeBytes("\x01vorbis\0\0\0\0\x02\x44\xAC\0\0\0\0\0\0\0\xF4\x01\0\0\0\0\0\xB8\x01",
                                                 30)], 0x02, 0, 0)];
        [file appendData:VibeOggPage(@[VibeBytes("\x03vorbis\x04\0\0\0vibe\0\0\0\0\x01", 20),
                                       VibeBytes("\x05vorbis\x00\x42\x43\x56\x01\x00\x00\x00", 15)], 0, 0, 1)];
    }
    for (uint32_t page = 0; page < 5; page++) {
        const uint8_t flags = page == 4 ? 0x04 : 0;
        uint8_t packet[40];
        memset(packet, (int)(0x30 + page), sizeof packet);
        packet[0] = opus ? 0xF8 : 0x00;
        [file appendData:VibeOggPage(@[VibeBytes((const char *)packet, sizeof packet)], flags,
                                     (int64_t)(page + 1) * 960, page + 2)];
    }
    return file;
}

#pragma mark - Audio payloads

static uint32_t VibeBE32(const uint8_t *p) {
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

// The bytes a tag write must never touch: an MP3's frames, a FLAC's frames
// and STREAMINFO, an MP4's mdat, a WAV's data chunk, an AIFF's SSND chunk,
// and an Ogg stream's audio pages, with their granules.
static NSData *VibeAudioPayload(NSURL *url) {
    NSData *data = [NSData dataWithContentsOfURL:url];
    const uint8_t *b = (const uint8_t *)data.bytes;
    const NSUInteger n = data.length;
    NSString *ext = url.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"mp3"]) {
        NSUInteger start = 0;
        if (n > 10 && memcmp(b, "ID3", 3) == 0) {
            start = 10 + ((b[6] & 0x7F) << 21 | (b[7] & 0x7F) << 14 | (b[8] & 0x7F) << 7 | (b[9] & 0x7F));
            if (b[5] & 0x10) start += 10;
        }
        NSUInteger end = n;
        if (n >= 128 && memcmp(b + n - 128, "TAG", 3) == 0) end -= 128;
        return [data subdataWithRange:NSMakeRange(start, end - start)];
    }
    if ([ext isEqualToString:@"flac"]) {
        NSMutableData *payload = [NSMutableData data];
        NSUInteger at = 4;
        BOOL last = NO;
        while (!last && at + 4 <= n) {
            last = (b[at] & 0x80) != 0;
            const NSUInteger length = (NSUInteger)b[at + 1] << 16 | (NSUInteger)b[at + 2] << 8 | b[at + 3];
            if ((b[at] & 0x7F) == 0) [payload appendBytes:b + at + 4 length:length];
            at += 4 + length;
        }
        [payload appendData:[data subdataWithRange:NSMakeRange(at, n - at)]];
        return payload;
    }
    if ([ext isEqualToString:@"m4a"]) {
        for (NSUInteger at = 0; at + 8 <= n;) {
            const NSUInteger size = VibeBE32(b + at);
            if (size < 8) break;
            if (memcmp(b + at + 4, "mdat", 4) == 0) return [data subdataWithRange:NSMakeRange(at + 8, size - 8)];
            at += size;
        }
        return nil;
    }
    if ([ext isEqualToString:@"wav"] || [ext isEqualToString:@"aif"]) {
        const BOOL wav = [ext isEqualToString:@"wav"];
        for (NSUInteger at = 12; at + 8 <= n;) {
            uint32_t size;
            memcpy(&size, b + at + 4, 4);
            if (!wav) size = VibeBE32(b + at + 4);
            if (memcmp(b + at, wav ? "data" : "SSND", 4) == 0) return [data subdataWithRange:NSMakeRange(at + 8, size)];
            at += 8 + size + (size & 1);
        }
        return nil;
    }
    if ([ext isEqualToString:@"ogg"] || [ext isEqualToString:@"opus"]) {
        NSMutableData *payload = [NSMutableData data];
        for (NSUInteger at = 0; at + 27 <= n;) {
            int64_t granule;
            memcpy(&granule, b + at + 6, 8);
            const NSUInteger segments = b[at + 26];
            NSUInteger length = 0;
            for (NSUInteger i = 0; i < segments; i++) length += b[at + 27 + i];
            const NSUInteger body = at + 27 + segments;
            if (granule > 0) {
                [payload appendBytes:&granule length:8];
                [payload appendBytes:b + body length:length];
            }
            at = body + length;
        }
        return payload;
    }
    return nil;
}

#pragma mark - Pictures

static NSData *VibeJPEG(uint8_t seed) {
    NSMutableData *data = [NSMutableData dataWithBytes:"\xFF\xD8\xFF\xE0" length:4];
    for (int i = 0; i < 600; i++) {
        const uint8_t byte = (uint8_t)(seed + i * 7);
        [data appendBytes:&byte length:1];
    }
    [data appendBytes:"\xFF\xD9" length:2];
    return data;
}

static NSData *VibePNG(uint8_t seed) {
    NSMutableData *data = [NSMutableData dataWithBytes:"\x89PNG\r\n\x1A\n" length:8];
    for (int i = 0; i < 500; i++) {
        const uint8_t byte = (uint8_t)(seed * 3 + i);
        [data appendBytes:&byte length:1];
    }
    return data;
}

static TagLib::ByteVector VibeTL(NSData *data) {
    return TagLib::ByteVector((const char *)data.bytes, (unsigned int)data.length);
}

static NSData *VibeNS(const TagLib::ByteVector &bytes) {
    return [NSData dataWithBytes:bytes.data() length:bytes.size()];
}

// Every picture in the file, in its order, as bytes.
static NSArray<NSData *> *VibePictures(NSURL *url) {
    NSMutableArray<NSData *> *pictures = [NSMutableArray array];
    TagLibAudioFile ref(url.fileSystemRepresentation, false);
    TagLib::File *file = ref.file();
    TagLib::ID3v2::Tag *id3 = nullptr;
    if (auto mpeg = dynamic_cast<TagLib::MPEG::File *>(file)) id3 = mpeg->ID3v2Tag();
    else if (auto wav = dynamic_cast<TagLib::RIFF::WAV::File *>(file)) id3 = wav->ID3v2Tag();
    else if (auto aiff = dynamic_cast<TagLib::RIFF::AIFF::File *>(file)) id3 = aiff->tag();
    if (id3) {
        for (auto frame : id3->frameList("APIC")) {
            [pictures addObject:VibeNS(dynamic_cast<TagLib::ID3v2::AttachedPictureFrame *>(frame)->picture())];
        }
    }
    else if (auto flac = dynamic_cast<TagLib::FLAC::File *>(file)) {
        for (auto picture : flac->pictureList()) [pictures addObject:VibeNS(picture->data())];
    }
    else if (auto xiph = dynamic_cast<TagLib::Ogg::XiphComment *>(file->tag())) {
        for (auto picture : xiph->pictureList()) [pictures addObject:VibeNS(picture->data())];
    }
    else if (auto mp4 = dynamic_cast<TagLib::MP4::File *>(file)) {
        for (const auto &art : mp4->tag()->item("covr").toCoverArtList()) [pictures addObject:VibeNS(art.data())];
    }
    return pictures;
}

static NSData *VibeFrontCover(NSURL *url) {
    TagLibAudioFile ref(url.fileSystemRepresentation, false);
    return ref.isNull() ? nil : albumArtDataFromTagLibFile(ref.file());
}

// A back cover, written with TagLib itself, beside whatever the file holds.
static void VibeAddBackCover(NSURL *url, NSData *png) {
    TagLibAudioFile ref(url.fileSystemRepresentation, false, nil, 0, true);
    TagLib::File *file = ref.file();
    auto apic = [&] {
        auto frame = new TagLib::ID3v2::AttachedPictureFrame();
        frame->setMimeType("image/png");
        frame->setType(TagLib::ID3v2::AttachedPictureFrame::BackCover);
        frame->setPicture(VibeTL(png));
        return frame;
    };
    auto block = [&] {
        auto picture = new TagLib::FLAC::Picture();
        picture->setMimeType("image/png");
        picture->setType(TagLib::FLAC::Picture::BackCover);
        picture->setData(VibeTL(png));
        return picture;
    };
    if (auto mpeg = dynamic_cast<TagLib::MPEG::File *>(file)) {
        const bool v3 = mpeg->hasID3v2Tag() && mpeg->ID3v2Tag()->header()->majorVersion() == 3;
        mpeg->ID3v2Tag(true)->addFrame(apic());
        mpeg->save(TagLib::MPEG::File::ID3v2, TagLib::File::StripNone, v3 ? TagLib::ID3v2::v3 : TagLib::ID3v2::v4);
    }
    else if (auto wav = dynamic_cast<TagLib::RIFF::WAV::File *>(file)) {
        wav->ID3v2Tag()->addFrame(apic());
        wav->save(TagLib::RIFF::WAV::File::ID3v2, TagLib::File::StripNone);
    }
    else if (auto aiff = dynamic_cast<TagLib::RIFF::AIFF::File *>(file)) {
        aiff->tag()->addFrame(apic());
        aiff->save();
    }
    else if (auto flac = dynamic_cast<TagLib::FLAC::File *>(file)) {
        flac->addPicture(block());
        flac->save();
    }
    else if (auto xiph = dynamic_cast<TagLib::Ogg::XiphComment *>(file->tag())) {
        xiph->addPicture(block());
        file->save();
    }
    else if (auto mp4 = dynamic_cast<TagLib::MP4::File *>(file)) {
        TagLib::MP4::CoverArtList list = mp4->tag()->item("covr").toCoverArtList();
        list.append(TagLib::MP4::CoverArt(TagLib::MP4::CoverArt::PNG, VibeTL(png)));
        mp4->tag()->setItem("covr", TagLib::MP4::Item(list));
        mp4->save();
    }
}

#pragma mark - The fields

// A value for every edited field, as each format reads it back.
static VibeTagFieldValues *VibeEveryField(void) {
    NSMutableDictionary<VibeTagField, NSArray<NSString *> *> *fields = [NSMutableDictionary dictionary];
    for (VibeTagField field in VibeTagFieldsEdited()) {
        fields[field] = @[[NSString stringWithFormat:@"Value of %@ é", field.lowercaseString]];
    }
    fields[VibeTagFieldDate] = @[@"2001-02-03"];
    fields[VibeTagFieldOriginalDate] = @[@"1999-05-01"];
    fields[VibeTagFieldTrackNumber] = @[@"3"];
    fields[VibeTagFieldTrackTotal] = @[@"12"];
    fields[VibeTagFieldDiscNumber] = @[@"1"];
    fields[VibeTagFieldDiscTotal] = @[@"2"];
    fields[VibeTagFieldCompilation] = @[@"1"];
    fields[VibeTagFieldBPM] = @[@"128"];
    fields[VibeTagFieldLanguage] = @[@"eng"];
    fields[VibeTagFieldISRC] = @[@"USRC17607839"];
    return fields;
}

// What the format reads back for a field it was given `written`.
static NSArray<NSString *> *VibeExpected(NSString *name, VibeTagField field, NSArray<NSString *> *written) {
    if ([name isEqualToString:@"id3v23.mp3"] && [field isEqualToString:VibeTagFieldOriginalDate]) {
        return @[[written.firstObject substringToIndex:4]];  // TORY holds the year
    }
    return written;
}

@implementation VibeTagWriterTests {
    NSURL *_dir;
}

- (void)setUp {
    [super setUp];
    _dir = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]
                      isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:_dir withIntermediateDirectories:YES attributes:nil
                                                 error:NULL];
}

- (void)tearDown {
    NSDirectoryEnumerator *walk = [NSFileManager.defaultManager enumeratorAtPath:_dir.path];
    for (NSString *name in walk) chmod([_dir URLByAppendingPathComponent:name].fileSystemRepresentation, 0644);
    [NSFileManager.defaultManager removeItemAtURL:_dir error:NULL];
    [super tearDown];
}

// Every format the writer writes, untagged but for id3v23.mp3, whose empty
// ID3v2.3 tag holds one frame so it keeps its version.
- (NSArray<NSString *> *)formats {
    return @[@"plain.mp3", @"id3v23.mp3", @"audio.m4a", @"audio.flac", @"audio.ogg", @"audio.opus", @"audio.wav",
             @"audio.aif"];
}

// Half a second of a tone in the format the name's extension names.
- (NSURL *)write:(NSString *)name {
    NSURL *url = [_dir URLByAppendingPathComponent:name];
    NSString *extension = name.pathExtension;
    if ([extension isEqualToString:@"mp3"]) {
        NSMutableData *bytes = [NSMutableData dataWithLength:38 * 1044];
        for (NSUInteger frame = 0; frame < 38; frame++) {
            uint8_t *at = (uint8_t *)bytes.mutableBytes + frame * 1044;
            memcpy(at, "\xFF\xFB\xE0\x00", 4);
            for (NSUInteger i = 4; i < 1044; i++) at[i] = (uint8_t)(frame + i);
        }
        XCTAssertTrue([bytes writeToURL:url atomically:YES]);
        if ([name hasPrefix:@"id3v23"]) {
            TagLib::MPEG::File file(url.fileSystemRepresentation);
            TagLib::PropertyMap properties;
            properties.insert("ENCODEDBY", TagLib::StringList("vibe"));
            file.ID3v2Tag(true)->setProperties(properties);
            XCTAssertTrue(file.save(TagLib::MPEG::File::ID3v2, TagLib::File::StripNone, TagLib::ID3v2::v3));
        }
        return url;
    }
    if ([extension isEqualToString:@"ogg"] || [extension isEqualToString:@"opus"]) {
        XCTAssertTrue([VibeOggFile([extension isEqualToString:@"opus"]) writeToURL:url atomically:YES]);
        return url;
    }
    NSDictionary<NSString *, NSNumber *> *codecs = @{@"m4a": @(kAudioFormatMPEG4AAC), @"flac": @(kAudioFormatFLAC),
                                                     @"wav": @(kAudioFormatLinearPCM), @"aif": @(kAudioFormatLinearPCM)};
    NSMutableDictionary *settings = [@{AVFormatIDKey: codecs[extension], AVSampleRateKey: @44100,
                                       AVNumberOfChannelsKey: @2} mutableCopy];
    if ([extension isEqualToString:@"flac"]) settings[AVEncoderBitDepthHintKey] = @16;
    if (codecs[extension].unsignedIntValue == kAudioFormatLinearPCM) {
        [settings addEntriesFromDictionary:@{AVLinearPCMBitDepthKey: @16, AVLinearPCMIsFloatKey: @NO,
                                             AVLinearPCMIsBigEndianKey: @([extension isEqualToString:@"aif"])}];
    }
    NSError *error = nil;
    @autoreleasepool {
        AVAudioFile *file = [[AVAudioFile alloc] initForWriting:url settings:settings
                                                   commonFormat:AVAudioPCMFormatInt16 interleaved:YES error:&error];
        AVAudioPCMBuffer *tone = [[AVAudioPCMBuffer alloc] initWithPCMFormat:file.processingFormat frameCapacity:22050];
        tone.frameLength = 22050;
        for (AVAudioFrameCount i = 0; i < 22050 * 2; i++) {
            tone.int16ChannelData[0][i] = (int16_t)(sin(i * 0.031) * 8000);
        }
        XCTAssertTrue([file writeFromBuffer:tone error:&error], @"%@: %@", name, error);
    }
    return url;
}

- (VibeTagFieldValues *)read:(NSURL *)url {
    NSError *error = nil;
    VibeTagFieldValues *fields = VibeTagLibReadFields(url.path, &error);
    XCTAssertNotNil(fields, @"%@: %@", url.lastPathComponent, error);
    return fields;
}

- (void)assertWrite:(NSURL *)url fields:(VibeTagFieldValues *)fields {
    NSError *error = nil;
    XCTAssertTrue(VibeTagLibWriteFields(url.path, fields, &error), @"%@: %@", url.lastPathComponent, error);
}

#pragma mark - Round trips

- (void)testEveryFieldRoundTripsInEveryFormat {
    VibeTagFieldValues *fields = VibeEveryField();
    for (NSString *name in self.formats) {
        NSURL *url = [self write:name];
        NSData *audio = VibeAudioPayload(url);
        XCTAssertGreaterThan(audio.length, 0u, @"%@", name);
        [self assertWrite:url fields:fields];
        VibeTagFieldValues *read = [self read:url];
        for (VibeTagField field in fields) {
            XCTAssertEqualObjects(read[field], VibeExpected(name, field, fields[field]), @"%@ %@", name, field);
        }
        XCTAssertEqualObjects(VibeAudioPayload(url), audio, @"%@", name);
    }
}

// A file's ID3v2 tag keeps its version. One with none gets 2.4.
- (void)testAnMP3KeepsItsID3v2Version {
    for (NSString *name in @[@"plain.mp3", @"id3v23.mp3"]) {
        NSURL *url = [self write:name];
        [self assertWrite:url fields:@{VibeTagFieldTitle: @[@"Title"], VibeTagFieldMood: @[@"Calm"]}];
        const uint8_t *bytes = (const uint8_t *)[NSData dataWithContentsOfURL:url].bytes;
        XCTAssertEqual(bytes[3], [name hasPrefix:@"id3v23"] ? 3 : 4, @"%@", name);
        XCTAssertEqualObjects([self read:url][VibeTagFieldMood], @[@"Calm"], @"%@", name);
    }
}

- (void)testTheCoverRoundTripsInEveryFormat {
    for (NSString *name in self.formats) {
        NSURL *url = [self write:name];
        NSData *audio = VibeAudioPayload(url);
        NSError *error = nil;
        XCTAssertTrue(VibeTagLibWriteFrontCover(url.path, VibeJPEG(1), @"image/jpeg", &error), @"%@: %@", name, error);
        XCTAssertEqualObjects(VibeFrontCover(url), VibeJPEG(1), @"%@", name);
        XCTAssertTrue(VibeTagLibWriteFrontCover(url.path, VibePNG(2), @"image/png", &error), @"%@: %@", name, error);
        XCTAssertEqualObjects(VibeFrontCover(url), VibePNG(2), @"%@", name);
        XCTAssertEqualObjects(VibePictures(url), @[VibePNG(2)], @"%@ replaced, not added", name);
        BOOL read = NO;
        NSData *art = nil;
        XCTAssertTrue(VibeTagLibWriteFrontCover(url.path, nil, nil, &error), @"%@: %@", name, error);
        read = VibeTagLibReadEmbeddedArt(url.path, nil, 0, &art);
        XCTAssertTrue(read, @"%@", name);
        XCTAssertNil(art, @"%@", name);
        XCTAssertEqualObjects(VibeAudioPayload(url), audio, @"%@", name);
    }
}

#pragma mark - What a write leaves

// A file with every field, a custom tag, a front and a back cover. A write
// of the title changes the title alone.
- (void)testOneFieldLeavesEverythingElse {
    NSMutableDictionary<VibeTagField, NSArray<NSString *> *> *fields = [VibeEveryField() mutableCopy];
    fields[@"VIBE_CUSTOM"] = @[@"kept"];
    for (NSString *name in self.formats) {
        NSURL *url = [self write:name];
        XCTAssertTrue(VibeTagLibWriteTags(url.path, fields, YES, VibeJPEG(3), @"image/jpeg", NULL), @"%@", name);
        VibeAddBackCover(url, VibePNG(4));
        if ([name hasSuffix:@"mp3"]) {
            TagLibAudioFile ref(url.fileSystemRepresentation, false, nil, 0, true);
            auto mpeg = dynamic_cast<TagLib::MPEG::File *>(ref.file());
            auto priv = new TagLib::ID3v2::PrivateFrame();
            priv->setOwner("org.example.vibe");
            priv->setData(TagLib::ByteVector("opaque", 6));
            mpeg->ID3v2Tag()->addFrame(priv);
            const bool v3 = mpeg->ID3v2Tag()->header()->majorVersion() == 3;
            XCTAssertTrue(mpeg->save(TagLib::MPEG::File::ID3v2, TagLib::File::StripNone,
                                     v3 ? TagLib::ID3v2::v3 : TagLib::ID3v2::v4));
        }
        VibeTagFieldValues *before = [self read:url];
        NSArray<NSData *> *pictures = VibePictures(url);
        XCTAssertEqual(pictures.count, 2u, @"%@", name);
        NSData *audio = VibeAudioPayload(url);
        NSData *md5 = nil;
        {
            TagLibAudioFile ref(url.fileSystemRepresentation);
            md5 = audioMD5FromTagLibFile(ref.file());
        }

        [self assertWrite:url fields:@{VibeTagFieldTitle: @[@"New Title"], VibeTagFieldComposer: @[]}];

        NSMutableDictionary *expected = [before mutableCopy];
        expected[VibeTagFieldTitle] = @[@"New Title"];
        [expected removeObjectForKey:VibeTagFieldComposer];
        XCTAssertEqualObjects([self read:url], expected, @"%@", name);
        XCTAssertEqualObjects(VibePictures(url), pictures, @"%@", name);
        XCTAssertEqualObjects(VibeAudioPayload(url), audio, @"%@", name);
        TagLibAudioFile ref(url.fileSystemRepresentation);
        XCTAssertEqualObjects(audioMD5FromTagLibFile(ref.file()), md5, @"%@", name);
        if ([name hasSuffix:@"mp3"]) {
            auto mpeg = dynamic_cast<TagLib::MPEG::File *>(ref.file());
            XCTAssertEqual(mpeg->ID3v2Tag()->frameList("PRIV").size(), 1u, @"%@", name);
        }
    }
}

// Removing the front cover leaves the back cover, which the read then answers.
- (void)testRemovingTheCoverLeavesOtherPictures {
    for (NSString *name in self.formats) {
        NSURL *url = [self write:name];
        XCTAssertTrue(VibeTagLibWriteFrontCover(url.path, VibeJPEG(5), @"image/jpeg", NULL), @"%@", name);
        VibeAddBackCover(url, VibePNG(6));
        XCTAssertEqualObjects(VibeFrontCover(url), VibeJPEG(5), @"%@", name);
        XCTAssertTrue(VibeTagLibWriteFrontCover(url.path, nil, nil, NULL), @"%@", name);
        XCTAssertEqualObjects(VibePictures(url), @[VibePNG(6)], @"%@", name);
        XCTAssertEqualObjects(VibeFrontCover(url), VibePNG(6), @"%@", name);
    }
}

// A total alone keeps the number, in the formats that hold both in one frame.
- (void)testATotalAloneKeepsTheNumber {
    for (NSString *name in self.formats) {
        NSURL *url = [self write:name];
        [self assertWrite:url fields:@{VibeTagFieldTrackNumber: @[@"3"], VibeTagFieldDiscNumber: @[@"1"],
                                       VibeTagFieldDiscTotal: @[@"2"]}];
        [self assertWrite:url fields:@{VibeTagFieldTrackTotal: @[@"12"], VibeTagFieldDiscTotal: @[]}];
        VibeTagFieldValues *read = [self read:url];
        XCTAssertEqualObjects(read[VibeTagFieldTrackNumber], @[@"3"], @"%@", name);
        XCTAssertEqualObjects(read[VibeTagFieldTrackTotal], @[@"12"], @"%@", name);
        XCTAssertEqualObjects(read[VibeTagFieldDiscNumber], @[@"1"], @"%@", name);
        XCTAssertNil(read[VibeTagFieldDiscTotal], @"%@", name);
    }
}

// TagLib reads the first tag that is not empty. A new ID3v2 tag starts with
// what the file read before, so an INFO-only WAV or an ID3v1-only MP3 keeps
// its other fields, and its old tag takes the edit too.
- (void)testANewID3v2TagKeepsTheOldTagsFields {
    NSURL *wav = [self write:@"info.wav"];
    {
        TagLib::RIFF::WAV::File file(wav.fileSystemRepresentation);
        file.InfoTag()->setArtist("Info Artist");
        file.InfoTag()->setTitle("Info Title");
        XCTAssertTrue(file.save(TagLib::RIFF::WAV::File::Info, TagLib::File::StripNone));
    }
    NSURL *mp3 = [self write:@"id3v1.mp3"];
    {
        TagLib::MPEG::File file(mp3.fileSystemRepresentation);
        file.ID3v1Tag(true)->setArtist("V1 Artist");
        file.ID3v1Tag(true)->setTitle("V1 Title");
        XCTAssertTrue(file.save(TagLib::MPEG::File::ID3v1, TagLib::File::StripNone));
    }
    for (NSURL *url in @[wav, mp3]) {
        NSString *artist = [self read:url][VibeTagFieldArtist].firstObject;
        XCTAssertNotNil(artist);
        [self assertWrite:url fields:@{VibeTagFieldTitle: @[@"New Title"]}];
        VibeTagFieldValues *read = [self read:url];
        XCTAssertEqualObjects(read[VibeTagFieldTitle], @[@"New Title"], @"%@", url.lastPathComponent);
        XCTAssertEqualObjects(read[VibeTagFieldArtist], @[artist], @"%@", url.lastPathComponent);
    }
    TagLib::RIFF::WAV::File file(wav.fileSystemRepresentation);
    XCTAssertTrue(file.hasID3v2Tag());
    XCTAssertEqual(file.InfoTag()->title(), TagLib::String("New Title"));
    TagLib::MPEG::File mpeg(mp3.fileSystemRepresentation);
    XCTAssertTrue(mpeg.hasID3v2Tag());
    XCTAssertEqual(mpeg.ID3v1Tag()->title(), TagLib::String("New Title"));
}

#pragma mark - Failures

- (void)assertFailure:(NSURL *)url code:(VibeTagWriteError)code fields:(VibeTagFieldValues *)fields {
    NSData *before = [NSData dataWithContentsOfURL:url];
    NSError *error = nil;
    XCTAssertFalse(VibeTagLibWriteFields(url.path, fields, &error), @"%@", url.lastPathComponent);
    XCTAssertEqualObjects(error.domain, VibeTagWriteErrorDomain, @"%@", url.lastPathComponent);
    XCTAssertEqual(error.code, code, @"%@: %@", url.lastPathComponent, error);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:url], before, @"%@", url.lastPathComponent);
}

- (void)testAReadOnlyFileFailsAndKeepsItsBytes {
    for (NSString *name in self.formats) {
        NSURL *url = [self write:name];
        XCTAssertEqual(chmod(url.fileSystemRepresentation, 0444), 0);
        [self assertFailure:url code:VibeTagWriteErrorReadOnly fields:@{VibeTagFieldTitle: @[@"Title"]}];
    }
}

- (void)testAMissingFileFailsToOpen {
    NSURL *url = [_dir URLByAppendingPathComponent:@"missing.flac"];
    NSError *error = nil;
    XCTAssertFalse(VibeTagLibWriteFields(url.path, @{VibeTagFieldTitle: @[@"Title"]}, &error));
    XCTAssertEqual(error.code, VibeTagWriteErrorOpenFailed);
}

// A metadata block, an atom, or a page that runs past the file, and bytes no
// parser takes: no parser takes the file, and its bytes stay.
- (void)testADamagedFileFailsAndKeepsItsBytes {
    NSURL *flac = [self write:@"damaged.flac"];
    NSMutableData *bytes = [NSMutableData dataWithContentsOfURL:flac];
    uint8_t *b = (uint8_t *)bytes.mutableBytes;
    b[4] &= 0x80;  // STREAMINFO keeps its type
    b[5] = 0xFF; b[6] = 0xFF; b[7] = 0xFF;
    [bytes writeToURL:flac atomically:YES];

    NSURL *m4a = [self write:@"damaged.m4a"];
    NSData *whole = [NSData dataWithContentsOfURL:m4a];
    NSURL *cut = [_dir URLByAppendingPathComponent:@"cut.m4a"];
    [[whole subdataWithRange:NSMakeRange(0, 40)] writeToURL:cut atomically:YES];

    NSURL *ogg = [_dir URLByAppendingPathComponent:@"damaged.opus"];
    NSMutableData *opus = [VibeOggFile(YES) mutableCopy];
    memcpy((uint8_t *)opus.mutableBytes + 28, "OpusJunk", 8);
    [opus writeToURL:ogg atomically:YES];

    NSURL *text = [_dir URLByAppendingPathComponent:@"text.mp3"];
    [[@"not audio at all" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:text atomically:YES];

    for (NSURL *url in @[flac, cut, ogg, text]) {
        [self assertFailure:url code:VibeTagWriteErrorNoParser fields:@{VibeTagFieldTitle: @[@"Title"]}];
    }
}

- (void)testABadArgumentFailsBeforeTheFileOpens {
    NSURL *url = [self write:@"audio.flac"];
    for (NSString *key in @[@"", @"A=B", @"PICTURE", @"TAB\tKEY"]) {
        [self assertFailure:url code:VibeTagWriteErrorInvalidField fields:@{key: @[@"x"]}];
    }
    NSData *before = [NSData dataWithContentsOfURL:url];
    NSError *error = nil;
    XCTAssertFalse(VibeTagLibWriteFrontCover(url.path, VibeJPEG(1), @"image/gif", &error));
    XCTAssertEqual(error.code, VibeTagWriteErrorInvalidImage);
    XCTAssertFalse(VibeTagLibWriteFrontCover(url.path, [NSData data], @"image/png", &error));
    XCTAssertEqual(error.code, VibeTagWriteErrorInvalidImage);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:url], before);
}

// MP4 holds the tempo and the compilation flag as numbers.
- (void)testMP4RefusesANumberItCannotHold {
    NSURL *url = [self write:@"audio.m4a"];
    [self assertFailure:url code:VibeTagWriteErrorUnsupportedValue fields:@{VibeTagFieldBPM: @[@"128.5"]}];
    [self assertFailure:url code:VibeTagWriteErrorUnsupportedValue fields:@{VibeTagFieldCompilation: @[@"yes"]}];
}

@end
