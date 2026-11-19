//
//  VibeTagWriterTests.mm
//  vibe-libs
//
//  VibeTagWriter's in-place write over the real TagLib, in every format it
//  writes: each field and the cover round trip, a write leaves what it does
//  not name and the audio's digest, and every refusal and failure leaves
//  the file's bytes. The files come from Tests/Support's fixtures, and the
//  Ogg pages from OggFixtures.h, since no Apple encoder writes Ogg.
//

#import <XCTest/XCTest.h>
#import <AVFoundation/AVFoundation.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <unistd.h>
#include <signal.h>
#include <sys/resource.h>
#include <sys/stat.h>

#import "AudioTrackMetadataTagFixtures.h"
#import "OggFixtures.h"
#import "TagLibAudioFile.h"
#import "VibeTagWriter.h"
#include "VibeCheckedFileStream.h"

#include <id3v2header.h>
#include <privateframe.h>
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation-html"
#include <textidentificationframe.h>
#pragma clang diagnostic pop
#include <xiphcomment.h>

@interface VibeTagWriterTests : XCTestCase
@end

#pragma mark - Reading back

static NSData *VibeNS(const TagLib::ByteVector &bytes) {
    return [NSData dataWithBytes:bytes.data() length:bytes.size()];
}

// Every picture in the file, in its order, as TagLib's complex properties
// list them.
static NSArray<NSData *> *VibePictures(NSURL *url) {
    NSMutableArray<NSData *> *pictures = [NSMutableArray array];
    TagLibAudioFile ref(url.fileSystemRepresentation, false);
    if (ref.isNull()) return pictures;
    for (const auto &picture : ref.file()->complexProperties("PICTURE")) {
        [pictures addObject:VibeNS(picture.value("data").toByteVector())];
    }
    return pictures;
}

static NSData *VibeFrontCover(NSURL *url) {
    TagLibAudioFile ref(url.fileSystemRepresentation, false);
    return ref.isNull() ? nil : albumArtDataFromTagLibFile(ref.file());
}

static NSData *VibeDigest(NSURL *url) {
    NSError *error = nil;
    NSData *digest = VibeTagLibAudioDigest(url.path, &error);
    if (!digest) NSLog(@"%@: %@", url.lastPathComponent, error);
    return digest;
}

// A real image's bytes, so the cover check's signatures hold.
static NSData *VibeJPEG(CGFloat shade) { return VibeImageOfColor(8, shade, 0.2, 0.3, UTTypeJPEG); }
static NSData *VibePNG(CGFloat shade) { return VibeImageOfColor(8, 0.3, shade, 0.2, UTTypePNG); }

// An image of one MIME type that ImageIO decodes. ImageIO writes no WebP,
// so WebP is one of two 1x1 files, lossless or lossy.
static NSData *VibeImageOfType(NSString *mime, int variant) {
    if ([mime isEqualToString:@"image/webp"]) {
        static const uint8_t lossless[] = {'R', 'I', 'F', 'F', 0x1A, 0, 0, 0, 'W', 'E', 'B', 'P', 'V', 'P', '8', 'L',
                                           0x0D, 0, 0, 0, 0x2F, 0, 0, 0, 0x10, 0x07, 0x10, 0x11, 0x11, 0x88, 0x88,
                                           0xFE, 0x07, 0};
        static const uint8_t lossy[] = {'R', 'I', 'F', 'F', 0x24, 0, 0, 0, 'W', 'E', 'B', 'P', 'V', 'P', '8', ' ',
                                        0x18, 0, 0, 0, 0x30, 0x01, 0, 0x9D, 0x01, 0x2A, 0x01, 0, 0x01, 0, 0x02, 0,
                                        0x34, 0x25, 0xA4, 0, 0x03, 0x70, 0, 0xFE, 0xFB, 0x94, 0, 0};
        return variant ? [NSData dataWithBytes:lossy length:sizeof lossy]
                       : [NSData dataWithBytes:lossless length:sizeof lossless];
    }
    NSDictionary<NSString *, UTType *> *types = @{@"image/jpeg": UTTypeJPEG, @"image/png": UTTypePNG,
                                                  @"image/gif": UTTypeGIF, @"image/bmp": UTTypeBMP,
                                                  @"image/tiff": UTTypeTIFF};
    return VibeImageOfColor(8, 0.1 + 0.4 * variant, 0.2, 0.3, types[mime]);
}

// The writes most tests make, flushed in full.
static BOOL VibeWriteFields(NSString *path, VibeTagFieldValues *fields, NSError **error) {
    return VibeTagLibWriteTags(path, fields, NO, nil, nil, VibeTagWriteSyncFull, error);
}

static BOOL VibeWriteFrontCover(NSString *path, NSData *data, NSString *mimeType, NSError **error) {
    return VibeTagLibWriteTags(path, nil, YES, data, mimeType, VibeTagWriteSyncFull, error);
}

// The shown picture and its type from its bytes, as an app saves them.
static NSArray *VibeSavedCover(NSURL *url) {
    NSArray<VibeTagPicture *> *pictures = nil;
    NSUInteger shown = NSNotFound;
    NSError *error = nil;
    if (!VibeTagLibReadPictures(url.path, &pictures, &shown, &error)) {
        NSLog(@"%@: %@", url.lastPathComponent, error);
        return nil;
    }
    if (shown == NSNotFound) return @[];
    return @[pictures[shown].data, pictures[shown].imageMIMEType ?: NSNull.null];
}

#pragma mark - The fields

// A value for every edited field, as each format reads it back.
static VibeTagFieldValues *VibeEveryField(void) {
    NSMutableDictionary<VibeTagField, NSArray<NSString *> *> *fields = [NSMutableDictionary dictionary];
    for (VibeTagField field in VibeTagFieldsEdited()) {
        fields[field] = @[[NSString stringWithFormat:@"Value of %@ é", field.lowercaseString]];
    }
    fields[VibeTagFieldDate] = @[@"2001-02-03"];
    fields[VibeTagFieldOriginalDate] = @[@"1999"];
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

// A tool's exit status.
static int VibeRun(NSArray<NSString *> *arguments) {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:arguments[0]];
    task.arguments = [arguments subarrayWithRange:NSMakeRange(1, arguments.count - 1)];
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) return -1;
    [task waitUntilExit];
    return task.terminationStatus;
}

// The process's footprint, which counts dirty memory and not a mapped
// file's clean pages.
static uint64_t VibeFootprint(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return 0;
    return info.phys_footprint;
}

// A FLAC or WAV of `size` bytes of noise, its audio after `padding` bytes of
// tag: a FLAC PADDING block, or a WAV junk chunk. The walk reads no frame,
// so the noise stands in for FLAC frames.
static void VibeWriteLargeAudio(NSString *path, NSString *kind, uint64_t size, uint32_t padding) {
    NSMutableData *head = [NSMutableData data];
    if ([kind isEqualToString:@"flac"]) {
        [head appendBytes:"fLaC" length:4];
        uint8_t info[38] = {padding ? (uint8_t)0x00 : (uint8_t)0x80, 0, 0, 34, 0x10, 0, 0x10, 0};
        info[14] = 0x0A; info[15] = 0xC4; info[16] = 0x42; info[17] = 0xF0;
        [head appendBytes:info length:sizeof info];
        if (padding) {
            const uint32_t length = padding - 4;
            const uint8_t block[4] = {0x81, (uint8_t)(length >> 16), (uint8_t)(length >> 8), (uint8_t)length};
            [head appendBytes:block length:4];
            [head increaseLengthBy:length];
        }
    }
    else {
        const uint32_t riff = (uint32_t)(4 + 24 + (padding ? 8 + padding : 0) + 8 + size);
        [head appendBytes:"RIFF" length:4];
        [head appendBytes:&riff length:4];
        [head appendBytes:"WAVEfmt " length:8];
        const uint8_t format[20] = {16, 0, 0, 0, 1, 0, 2, 0, 0x44, 0xAC, 0, 0, 0x10, 0xB1, 0x02, 0, 4, 0, 16, 0};
        [head appendBytes:format length:sizeof format];
        if (padding) {
            [head appendBytes:"JUNK" length:4];
            [head appendBytes:&padding length:4];
            [head increaseLengthBy:padding];
        }
        const uint32_t data = (uint32_t)size;
        [head appendBytes:"data" length:4];
        [head appendBytes:&data length:4];
    }
    [NSFileManager.defaultManager createFileAtPath:path contents:head attributes:nil];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    [handle seekToEndOfFile];
    NSMutableData *block = [NSMutableData dataWithLength:64 << 20];
    uint32_t seed = 12345;
    for (uint64_t written = 0; written < size; written += block.length) {
        uint32_t *words = (uint32_t *)block.mutableBytes;
        for (NSUInteger i = 0; i < block.length / 4; i++) words[i] = seed = seed * 1664525u + 1013904223u;
        [handle writeData:block];
    }
    [handle closeFile];
}

@implementation VibeTagWriterTests {
    NSURL *_dir;
}

- (void)setUp {
    [super setUp];
    _dir = VibeTagFixtureDirectory();
}

- (void)tearDown {
    for (NSString *name in [NSFileManager.defaultManager enumeratorAtPath:_dir.path]) {
        chmod([_dir URLByAppendingPathComponent:name].fileSystemRepresentation, 0644);
    }
    [NSFileManager.defaultManager removeItemAtURL:_dir error:NULL];
    [super tearDown];
}

// Every format the writer writes. id3v23.mp3's tag is ID3v2.3, holding one
// frame so it keeps its version. plain.mp3 has no tag.
- (NSArray<NSString *> *)formats {
    return @[@"plain.mp3", @"id3v23.mp3", @"audio.m4a", @"audio.flac", @"audio.ogg", @"audio.opus", @"audio.wav",
             @"audio.aif"];
}

- (NSURL *)write:(NSString *)name {
    NSURL *url = [_dir URLByAppendingPathComponent:name];
    NSString *extension = name.pathExtension;
    NSError *error = nil;
    if ([extension isEqualToString:@"mp3"]) {
        XCTAssertTrue([VibeMP3WithInfoFrame(38, NO) writeToURL:url atomically:YES]);
        if ([name hasPrefix:@"id3v23"]) {
            TagLib::MPEG::File file(url.fileSystemRepresentation);
            TagLib::PropertyMap properties;
            properties.insert("ENCODEDBY", TagLib::StringList("vibe"));
            file.ID3v2Tag(true)->setProperties(properties);
            XCTAssertTrue(file.save(TagLib::MPEG::File::ID3v2, TagLib::File::StripNone, TagLib::ID3v2::v3));
        }
    }
    else if ([extension isEqualToString:@"ogg"] || [extension isEqualToString:@"opus"]) {
        XCTAssertTrue([VibeOggTagFile([extension isEqualToString:@"opus"]) writeToURL:url atomically:YES]);
    }
    else if ([extension isEqualToString:@"m4a"] || [extension isEqualToString:@"flac"]) {
        XCTAssertNotNil(VibeTagFixtureEncode(url, [extension isEqualToString:@"m4a"] ? kAudioFormatMPEG4AAC
                                                                                     : kAudioFormatFLAC));
    }
    else {
        XCTAssertNotNil(VibeWriteFixture(url, VibeToneBuffer(22050, 44100, 2, AVAudioPCMFormatInt16), &error),
                        @"%@: %@", name, error);
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
    XCTAssertTrue(VibeWriteFields(url.path, fields, &error), @"%@: %@", url.lastPathComponent, error);
}

// A write that fails with `code` and leaves every byte.
- (void)assertFailure:(NSURL *)url code:(VibeTagWriteError)code write:(BOOL (^)(NSError **error))write {
    NSData *before = [NSData dataWithContentsOfURL:url];
    NSError *error = nil;
    XCTAssertFalse(write(&error), @"%@", url.lastPathComponent);
    XCTAssertEqualObjects(error.domain, VibeTagWriteErrorDomain, @"%@", url.lastPathComponent);
    XCTAssertEqual(error.code, code, @"%@: %@", url.lastPathComponent, error);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:url], before, @"%@", url.lastPathComponent);
}

- (void)assertFailure:(NSURL *)url code:(VibeTagWriteError)code fields:(VibeTagFieldValues *)fields {
    [self assertFailure:url code:code write:^BOOL(NSError **error) {
        return VibeWriteFields(url.path, fields, error);
    }];
}

#pragma mark - Round trips

- (void)testEveryFieldRoundTripsInEveryFormat {
    VibeTagFieldValues *fields = VibeEveryField();
    for (NSString *name in self.formats) {
        NSURL *url = [self write:name];
        NSData *audio = VibeDigest(url);
        XCTAssertNotNil(audio, @"%@", name);
        [self assertWrite:url fields:fields];
        VibeTagFieldValues *read = [self read:url];
        for (VibeTagField field in fields) {
            XCTAssertEqualObjects(read[field], fields[field], @"%@ %@", name, field);
        }
        XCTAssertEqualObjects(VibeDigest(url), audio, @"%@", name);
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

- (void)testSeveralValuesRoundTripInEveryFormat {
    for (NSString *name in self.formats) {
        NSURL *url = [self write:name];
        [self assertWrite:url fields:@{VibeTagFieldArtist: @[@"One", @"Two", @"Three"]}];
        XCTAssertEqualObjects([self read:url][VibeTagFieldArtist], (@[@"One", @"Two", @"Three"]), @"%@", name);
    }
}

- (void)testTheCoverRoundTripsInEveryFormat {
    for (NSString *name in self.formats) {
        NSURL *url = [self write:name];
        NSData *audio = VibeDigest(url);
        NSError *error = nil;
        XCTAssertTrue(VibeWriteFrontCover(url.path, VibeJPEG(0.1), @"image/jpeg", &error), @"%@: %@", name, error);
        XCTAssertEqualObjects(VibeFrontCover(url), VibeJPEG(0.1), @"%@", name);
        XCTAssertTrue(VibeWriteFrontCover(url.path, VibePNG(0.2), @"image/png", &error), @"%@: %@", name, error);
        XCTAssertEqualObjects(VibeFrontCover(url), VibePNG(0.2), @"%@", name);
        XCTAssertEqualObjects(VibePictures(url), @[VibePNG(0.2)], @"%@ replaced, not added", name);
        XCTAssertTrue(VibeWriteFrontCover(url.path, nil, nil, &error), @"%@: %@", name, error);
        NSData *art = nil;
        XCTAssertTrue(VibeTagLibReadEmbeddedArt(url.path, nil, 0, &art), @"%@", name);
        XCTAssertNil(art, @"%@", name);
        XCTAssertEqualObjects(VibeDigest(url), audio, @"%@", name);
    }
}

// Each image type round trips byte for byte in every format that holds it:
// written, read back with its type, replaced, and put back from what the
// read saved. MP4 holds no TIFF or WebP, and refuses them.
- (void)testEveryCoverTypeRoundTripsWhereTheFormatHoldsIt {
    for (NSString *mime in VibeTagCoverMIMETypes()) {
        for (int variant = 0; variant < 2; variant++) {
            CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)VibeImageOfType(mime, variant), NULL);
            XCTAssertEqual(source ? CGImageSourceGetCount(source) : 0, (size_t)1, @"%@ decodes", mime);
            if (source) CFRelease(source);
        }
    }
    for (NSString *name in self.formats) {
        for (NSString *mime in VibeTagCoverMIMETypes()) {
            NSURL *url = [self write:name];
            NSData *audio = VibeDigest(url);
            NSData *image = VibeImageOfType(mime, 0);
            const BOOL mp4 = [name.pathExtension isEqualToString:@"m4a"];
            if (mp4 && ([mime isEqualToString:@"image/tiff"] || [mime isEqualToString:@"image/webp"])) {
                [self assertFailure:url code:VibeTagWriteErrorInvalidImage write:^BOOL(NSError **error) {
                    return VibeWriteFrontCover(url.path, image, mime, error);
                }];
                continue;
            }
            NSError *error = nil;
            XCTAssertTrue(VibeWriteFrontCover(url.path, image, mime, &error), @"%@ %@: %@", name, mime, error);
            NSArray *saved = VibeSavedCover(url);
            XCTAssertEqualObjects(saved, (@[image, mime]), @"%@ %@", name, mime);
            XCTAssertTrue(VibeWriteFrontCover(url.path, VibeJPEG(0.7), @"image/jpeg", &error), @"%@", error);
            XCTAssertEqualObjects(VibeSavedCover(url), (@[VibeJPEG(0.7), @"image/jpeg"]), @"%@ %@", name, mime);
            XCTAssertTrue(VibeWriteFrontCover(url.path, saved[0], saved[1], &error), @"%@ %@: %@", name, mime,
                          error);
            XCTAssertEqualObjects(VibeSavedCover(url), (@[image, mime]), @"%@ %@ put back", name, mime);
            XCTAssertEqualObjects(VibePictures(url), @[image], @"%@ %@ replaced, not added", name, mime);
            XCTAssertTrue(VibeWriteFrontCover(url.path, VibeImageOfType(mime, 1), mime, &error), @"%@", error);
            XCTAssertEqualObjects(VibeFrontCover(url), VibeImageOfType(mime, 1), @"%@ %@", name, mime);
            XCTAssertEqualObjects(VibeDigest(url), audio, @"%@ %@", name, mime);
        }
    }
}

// Adds pictures to the file with TagLib itself, each as given. MP4 takes
// the bytes and the typed MIME type alone.
- (void)addPictures:(NSArray<VibeTagPicture *> *)pictures to:(NSURL *)url {
    NSString *extension = url.pathExtension;
    const char *path = url.fileSystemRepresentation;
    auto apic = [&](TagLib::ID3v2::Tag *tag) {
        for (VibeTagPicture *picture in pictures) {
            VibeAddAPIC(tag, picture.data, static_cast<TagLib::ID3v2::AttachedPictureFrame::Type>(picture.type),
                        picture.mimeType, picture.pictureDescription);
        }
    };
    auto block = [&](VibeTagPicture *picture) {
        TagLib::FLAC::Picture *block = VibeFLACPicture(picture.data,
                                                       static_cast<TagLib::FLAC::Picture::Type>(picture.type),
                                                       picture.mimeType, picture.pictureDescription);
        block->setWidth((int)picture.width);
        block->setHeight((int)picture.height);
        block->setColorDepth((int)picture.colorDepth);
        block->setNumColors((int)picture.colorCount);
        return block;
    };
    if ([extension isEqualToString:@"mp3"]) {
        TagLib::MPEG::File file(path);
        const bool v3 = file.hasID3v2Tag() && file.ID3v2Tag()->header()->majorVersion() == 3;
        apic(file.ID3v2Tag(true));
        XCTAssertTrue(file.save(TagLib::MPEG::File::ID3v2, TagLib::File::StripNone,
                                v3 ? TagLib::ID3v2::v3 : TagLib::ID3v2::v4));
    }
    else if ([extension isEqualToString:@"wav"]) {
        TagLib::RIFF::WAV::File file(path);
        apic(file.ID3v2Tag());
        XCTAssertTrue(file.save());
    }
    else if ([extension isEqualToString:@"aif"]) {
        TagLib::RIFF::AIFF::File file(path);
        apic(file.tag());
        XCTAssertTrue(file.save());
    }
    else if ([extension isEqualToString:@"flac"]) {
        TagLib::FLAC::File file(path);
        for (VibeTagPicture *picture in pictures) file.addPicture(block(picture));
        XCTAssertTrue(file.save());
    }
    else if ([extension isEqualToString:@"ogg"]) {
        TagLib::Ogg::Vorbis::File file(path);
        for (VibeTagPicture *picture in pictures) file.tag()->addPicture(block(picture));
        XCTAssertTrue(file.save());
    }
    else if ([extension isEqualToString:@"opus"]) {
        TagLib::Ogg::Opus::File file(path);
        for (VibeTagPicture *picture in pictures) file.tag()->addPicture(block(picture));
        XCTAssertTrue(file.save());
    }
    else {
        TagLib::MP4::File file(path);
        TagLib::MP4::CoverArtList list = file.tag()->item("covr").toCoverArtList();
        NSDictionary<NSString *, NSNumber *> *formats = @{@"image/jpeg": @(TagLib::MP4::CoverArt::JPEG),
                                                          @"image/png": @(TagLib::MP4::CoverArt::PNG),
                                                          @"image/gif": @(TagLib::MP4::CoverArt::GIF),
                                                          @"image/bmp": @(TagLib::MP4::CoverArt::BMP)};
        for (VibeTagPicture *picture in pictures) {
            const auto format = (TagLib::MP4::CoverArt::Format)(picture.mimeType ? formats[picture.mimeType].intValue
                                                                                 : TagLib::MP4::CoverArt::Unknown);
            list.append(TagLib::MP4::CoverArt(format, VibeTagBytes(picture.data)));
        }
        if (list.isEmpty()) return;
        file.tag()->setItem("covr", TagLib::MP4::Item(list));
        XCTAssertTrue(file.save());
    }
}

- (NSArray<VibeTagPicture *> *)picturesOf:(NSURL *)url shown:(NSUInteger *)shown {
    NSArray<VibeTagPicture *> *pictures = nil;
    NSError *error = nil;
    XCTAssertTrue(VibeTagLibReadPictures(url.path, &pictures, shown, &error), @"%@: %@", url.lastPathComponent, error);
    return pictures;
}

// A picture as each format stores it: MP4 keeps the bytes and typed
// format, and FLAC and Xiph keep the dimension fields.
static VibeTagPicture *VibeStored(VibeTagPicture *picture, NSString *format) {
    if ([format isEqualToString:@"m4a"]) {
        NSSet *typed = [NSSet setWithArray:@[@"image/jpeg", @"image/png", @"image/gif", @"image/bmp"]];
        return [[VibeTagPicture alloc] initWithData:picture.data
                                           mimeType:[typed containsObject:picture.mimeType] ? picture.mimeType : nil
                                               type:VibeTagPictureTypeUntyped description:nil];
    }
    if ([@[@"flac", @"ogg", @"opus"] containsObject:format]) return picture;
    return [[VibeTagPicture alloc] initWithData:picture.data mimeType:picture.mimeType type:picture.type
                                    description:picture.pictureDescription];
}

// Removes the cover, and answers what the art read then shows.
- (NSData *)removeCoverOf:(NSURL *)url {
    NSError *error = nil;
    XCTAssertTrue(VibeWriteFrontCover(url.path, nil, nil, &error), @"%@: %@", url.lastPathComponent, error);
    NSData *art = nil;
    XCTAssertTrue(VibeTagLibReadEmbeddedArt(url.path, nil, 0, &art));
    return art;
}

// A removal takes every front cover, or when the file has none, the one
// picture the art read shows, whatever its type. TRAP: taking every "other"
// picture first took one that never showed, and left the one that did. So
// each removal takes what shows, until nothing does. MP4's entries are
// untyped, and go one a removal too.
- (void)testEachRemovalTakesWhatShows {
    auto picture = [](NSData *data, NSInteger type) {
        return [[VibeTagPicture alloc] initWithData:data mimeType:@"image/png" type:(VibeTagPictureType)type
                                        description:nil];
    };
    VibeTagPicture *back = picture(VibePNG(0.1), VibeTagPictureTypeBackCover);
    VibeTagPicture *icon = picture(VibePNG(0.3), 1);
    VibeTagPicture *other = picture(VibePNG(0.5), VibeTagPictureTypeOther);
    VibeTagPicture *second = picture(VibePNG(0.7), VibeTagPictureTypeOther);
    for (NSString *name in self.formats) {
        const BOOL mp4 = [name.pathExtension isEqualToString:@"m4a"];
        for (NSArray<VibeTagPicture *> *pictures in @[@[back, other], @[icon, other], @[other, second], @[other]]) {
            if (mp4 && pictures.count == 2 && pictures[0] == icon) continue;  // the same two untyped entries
            NSURL *url = [self write:name];
            [self addPictures:pictures to:url];
            NSData *art = nil;
            XCTAssertTrue(VibeTagLibReadEmbeddedArt(url.path, nil, 0, &art));
            for (NSUInteger i = 0; i < pictures.count; i++) {
                XCTAssertEqualObjects(art, pictures[i].data, @"%@ %@ shows picture %lu", name, pictures,
                                      (unsigned long)i);
                NSData *next = [self removeCoverOf:url];
                XCTAssertEqualObjects([self picturesOf:url shown:NULL].firstObject.data, next, @"%@", name);
                art = next;
            }
            XCTAssertNil(art, @"%@ %@ shows nothing", name, pictures);
            XCTAssertEqualObjects([self picturesOf:url shown:NULL], @[], @"%@", name);
        }
    }
}

// A replacement takes what shows in the same way: on a file of a back cover
// and an "other" picture, the back cover goes, and the "other" stays.
- (void)testAReplacementTakesWhatShows {
    VibeTagPicture *back = [[VibeTagPicture alloc] initWithData:VibePNG(0.1) mimeType:@"image/png"
                                                           type:VibeTagPictureTypeBackCover description:nil];
    VibeTagPicture *other = [[VibeTagPicture alloc] initWithData:VibePNG(0.5) mimeType:@"image/png"
                                                            type:VibeTagPictureTypeOther description:nil];
    for (NSString *name in self.formats) {
        NSURL *url = [self write:name];
        [self addPictures:@[back, other] to:url];
        XCTAssertTrue(VibeWriteFrontCover(url.path, VibeJPEG(0.9), @"image/jpeg", NULL), @"%@", name);
        NSArray<NSData *> *left = [[self picturesOf:url shown:NULL] valueForKey:@"data"];
        XCTAssertEqualObjects([NSSet setWithArray:left], ([NSSet setWithArray:@[VibeJPEG(0.9), other.data]]), @"%@", name);
        XCTAssertEqualObjects(VibeFrontCover(url), VibeJPEG(0.9), @"%@", name);
    }
}

// A file of booklet scans, with no front cover or "other" picture, loses
// only the page that shows. The rest stay.
- (void)testARemovalLeavesPicturesThatNeverShowed {
    NSMutableArray<VibeTagPicture *> *booklet = [NSMutableArray array];
    [booklet addObject:[[VibeTagPicture alloc] initWithData:VibePNG(0.05) mimeType:@"image/png"
                                                       type:VibeTagPictureTypeBackCover description:@"Back"]];
    for (int page = 1; page <= 8; page++) {
        [booklet addObject:[[VibeTagPicture alloc] initWithData:VibePNG(0.1 * page) mimeType:@"image/png"
                                                           type:(VibeTagPictureType)5
                                                    description:[NSString stringWithFormat:@"Page %d", page]]];
    }
    [booklet addObject:[[VibeTagPicture alloc] initWithData:VibeJPEG(0.9) mimeType:@"image/jpeg"
                                                       type:(VibeTagPictureType)8 description:@"Artist"]];
    for (NSString *name in self.formats) {
        if ([name.pathExtension isEqualToString:@"m4a"]) continue;
        NSURL *url = [self write:name];
        [self addPictures:booklet to:url];
        XCTAssertEqualObjects([self removeCoverOf:url], booklet[1].data, @"%@: the first page shows next", name);
        XCTAssertEqualObjects([self picturesOf:url shown:NULL],
                              [booklet subarrayWithRange:NSMakeRange(1, booklet.count - 1)], @"%@", name);
    }
}

// TRAP: the art read skips a picture with no bytes, so the removal and the
// shown index skip it too. A 0-byte front cover hides nothing: the back
// cover behind it shows, and a removal takes that. An MP4 whose first covr
// entry is empty shows its second.
- (void)testAPictureWithNoBytesNeverShows {
    VibeTagPicture *empty = [[VibeTagPicture alloc] initWithData:[NSData data] mimeType:@"image/png"
                                                            type:VibeTagPictureTypeFrontCover description:nil];
    VibeTagPicture *back = [[VibeTagPicture alloc] initWithData:VibePNG(0.8) mimeType:@"image/png"
                                                           type:VibeTagPictureTypeBackCover description:nil];
    for (NSString *name in self.formats) {
        NSURL *url = [self write:name];
        [self addPictures:@[empty, back] to:url];
        NSData *art = nil;
        XCTAssertTrue(VibeTagLibReadEmbeddedArt(url.path, nil, 0, &art));
        XCTAssertEqualObjects(art, back.data, @"%@ shows the picture with bytes", name);
        NSUInteger shown = NSNotFound;
        NSArray<VibeTagPicture *> *pictures = [self picturesOf:url shown:&shown];
        XCTAssertEqual(pictures.count, 1u, @"%@ lists only the picture with bytes", name);
        XCTAssertEqual(shown, 0u, @"%@", name);
        XCTAssertNil([self removeCoverOf:url], @"%@: the removal takes what showed", name);
    }
}

// An undo puts every picture back as it was, from what the read saved:
// each type, MIME string, description, order, and FLAC's dimensions, after
// a replacement or a removal. An Other picture stays Other, and an MP4's
// untyped TIFF stays untyped.
- (void)testEveryPictureIsPutBackAsItWas {
    VibeTagPicture *front = [[VibeTagPicture alloc] initWithData:VibePNG(0.1) mimeType:@"image/png"
                                                            type:VibeTagPictureTypeFrontCover description:@"Front é"
                                                           width:8 height:8 colorDepth:24 colorCount:0];
    VibeTagPicture *other = [[VibeTagPicture alloc] initWithData:VibeImageOfType(@"image/gif", 0)
                                                        mimeType:@"image/jpeg" type:VibeTagPictureTypeOther
                                                     description:@"ffmpeg"];
    VibeTagPicture *back = [[VibeTagPicture alloc] initWithData:VibeImageOfType(@"image/bmp", 0) mimeType:@"image/bmp"
                                                           type:VibeTagPictureTypeBackCover description:@""];
    VibeTagPicture *tiff = [[VibeTagPicture alloc] initWithData:VibeImageOfType(@"image/tiff", 0) mimeType:nil
                                                           type:(VibeTagPictureType)8 description:@"Artist"];
    for (NSArray<VibeTagPicture *> *given in @[@[other, front, back], @[other], @[tiff, back], @[]]) {
        for (NSString *name in self.formats) {
            NSURL *url = [self write:name];
            NSData *audio = VibeDigest(url);
            [self addPictures:given to:url];
            NSUInteger shown = 0;
            NSArray<VibeTagPicture *> *saved = [self picturesOf:url shown:&shown];
            NSMutableArray *stored = [NSMutableArray array];
            for (VibeTagPicture *picture in given) [stored addObject:VibeStored(picture, name.pathExtension)];
            XCTAssertEqualObjects(saved, stored, @"%@", name);
            NSData *art = nil;
            VibeTagLibReadEmbeddedArt(url.path, nil, 0, &art);
            XCTAssertEqualObjects(shown == NSNotFound ? nil : saved[shown].data, art, @"%@ shown", name);
            for (NSNumber *removes in @[@NO, @YES]) {
                NSError *error = nil;
                XCTAssertTrue(VibeWriteFrontCover(url.path, removes.boolValue ? nil : VibeJPEG(0.9),
                                                        removes.boolValue ? nil : @"image/jpeg", &error),
                              @"%@: %@", name, error);
                XCTAssertTrue(VibeTagLibWritePictures(url.path, saved, VibeTagWriteSyncBarrier, &error),
                              @"%@: %@", name, error);
                NSUInteger after = 0;
                XCTAssertEqualObjects([self picturesOf:url shown:&after], saved, @"%@ %@", name, removes);
                XCTAssertEqual(after, shown, @"%@", name);
            }
            XCTAssertEqualObjects(VibeDigest(url), audio, @"%@", name);
        }
    }
}

// VibeTagLibPicturesFit answers as VibeTagLibWritePictures does, in every
// format, on each of the write's own refusals and on lists it takes. So an
// app can ask before an edit, and the two cannot drift.
- (void)testPicturesFitAnswersAsTheWriteDoes {
    NSMutableData *big = [NSMutableData dataWithLength:16000001];
    memcpy(big.mutableBytes, "\x89PNG", 4);
    NSData *atLimit = [big subdataWithRange:NSMakeRange(0, 16000000)];
    auto picture = [](NSData *data, NSInteger type) {
        return [[VibeTagPicture alloc] initWithData:data mimeType:@"image/png" type:(VibeTagPictureType)type
                                        description:nil];
    };
    NSMutableArray *many = [NSMutableArray array];
    for (int i = 0; i < 16; i++) [many addObject:picture(atLimit, VibeTagPictureTypeOther)];
    NSArray<NSArray<VibeTagPicture *> *> *lists = @[
        @[], @[picture(VibePNG(0.1), VibeTagPictureTypeUntyped)], @[picture(VibePNG(0.1), VibeTagPictureTypeFrontCover)],
        @[picture(VibePNG(0.1), VibeTagPictureTypeBackCover)], @[picture(VibePNG(0.1), VibeTagPictureTypeOther)],
        @[picture(VibePNG(0.1), 20)], @[picture(VibePNG(0.1), 21)], @[picture(VibePNG(0.1), -2)],
        @[picture([NSData data], VibeTagPictureTypeOther)], @[picture(big, VibeTagPictureTypeOther)], many,
    ];
    for (NSString *name in self.formats) {
        for (NSArray<VibeTagPicture *> *list in lists) {
            NSURL *url = [self write:name];
            NSData *before = [NSData dataWithContentsOfURL:url];
            NSError *fitError = nil, *writeError = nil;
            const BOOL fits = VibeTagLibPicturesFit(url.path, list, &fitError);
            XCTAssertEqualObjects([NSData dataWithContentsOfURL:url], before, @"%@: the check writes nothing", name);
            const BOOL wrote = VibeTagLibWritePictures(url.path, list, VibeTagWriteSyncFull, &writeError);
            XCTAssertEqual(fits, wrote, @"%@ %@: %@ / %@", name, list, fitError, writeError);
            XCTAssertEqual(fitError.code, writeError.code, @"%@ %@", name, list);
            if (!wrote) XCTAssertEqualObjects([NSData dataWithContentsOfURL:url], before, @"%@", name);
        }
    }
}

// A picture is a value: two with every field equal are equal and hash
// alike, and any one field told apart makes them differ.
- (void)testAPictureIsAValue {
    VibeTagPicture *(^make)(NSData *, NSString *, NSInteger, NSString *, NSUInteger) =
            ^(NSData *data, NSString *mime, NSInteger type, NSString *text, NSUInteger width) {
        return [[VibeTagPicture alloc] initWithData:data mimeType:mime type:(VibeTagPictureType)type description:text
                                              width:width height:8 colorDepth:24 colorCount:0];
    };
    VibeTagPicture *one = make(VibePNG(0.1), @"image/png", 3, @"Front", 8);
    VibeTagPicture *same = make([VibePNG(0.1) mutableCopy], [@"image/png" mutableCopy], 3, [@"Front" mutableCopy], 8);
    XCTAssertEqualObjects(one, same);
    XCTAssertEqual(one.hash, same.hash);
    XCTAssertEqual(([NSSet setWithArray:@[one, same]].count), 1u);
    for (VibeTagPicture *other in @[make(VibePNG(0.2), @"image/png", 3, @"Front", 8),
                                    make(VibePNG(0.1), @"image/jpeg", 3, @"Front", 8),
                                    make(VibePNG(0.1), nil, 3, @"Front", 8),
                                    make(VibePNG(0.1), @"image/png", 4, @"Front", 8),
                                    make(VibePNG(0.1), @"image/png", 3, @"Back", 8),
                                    make(VibePNG(0.1), @"image/png", 3, @"Front", 9)]) {
        XCTAssertNotEqualObjects(one, other);
        // NSData's hash reads only the bytes' start, so two images may hash
        // alike. Every other field tells them apart.
        if ([other.data isEqualToData:one.data]) XCTAssertNotEqual(one.hash, other.hash, @"%@", other);
    }
}

// A picture with no bytes or no known type is refused before any write.
- (void)testAPictureMustHoldBytesAndAType {
    NSURL *url = [self write:@"audio.flac"];
    for (VibeTagPicture *picture in @[[[VibeTagPicture alloc] initWithData:[NSData data] mimeType:@"image/png"
                                                                      type:VibeTagPictureTypeOther description:nil],
                                      [[VibeTagPicture alloc] initWithData:VibePNG(0.1) mimeType:@"image/png"
                                                                      type:(VibeTagPictureType)21 description:nil]]) {
        [self assertFailure:url code:VibeTagWriteErrorInvalidImage write:^BOOL(NSError **error) {
            return VibeTagLibWritePictures(url.path, @[picture], VibeTagWriteSyncFull, error);
        }];
    }
    // One past the limit of a picture, and sixteen at it, past the limit of
    // them all. Both are refused before the file opens.
    NSMutableData *big = [NSMutableData dataWithLength:16000001];
    memcpy(big.mutableBytes, "\x89PNG", 4);
    VibeTagPicture *tooBig = [[VibeTagPicture alloc] initWithData:big mimeType:@"image/png"
                                                             type:VibeTagPictureTypeOther description:nil];
    VibeTagPicture *atLimit = [[VibeTagPicture alloc] initWithData:[big subdataWithRange:NSMakeRange(0, 16000000)]
                                                          mimeType:@"image/png" type:VibeTagPictureTypeOther
                                                       description:nil];
    NSMutableArray *many = [NSMutableArray array];
    for (int i = 0; i < 16; i++) [many addObject:atLimit];
    for (NSArray *pictures in @[@[tooBig], many]) {
        [self assertFailure:url code:VibeTagWriteErrorInvalidImage write:^BOOL(NSError **error) {
            return VibeTagLibWritePictures(url.path, pictures, VibeTagWriteSyncFull, error);
        }];
    }
}

// The type comes from the bytes when the tag's own is wrong or missing, and
// from the tag when the bytes name none.
- (void)testTheCoverReadFindsTheTrueType {
    NSData *png = VibePNG(0.4), *gif = VibeImageOfType(@"image/gif", 0), *bmp = VibeImageOfType(@"image/bmp", 0);
    NSData *unknown = [@"not an image" dataUsingEncoding:NSASCIIStringEncoding];

    auto front = [](NSData *data, NSString *mimeType) {
        return [[VibeTagPicture alloc] initWithData:data mimeType:mimeType type:VibeTagPictureTypeFrontCover
                                        description:nil];
    };
    NSURL *mp3 = [self write:@"plain.mp3"];
    [self addPictures:@[front(png, @"image/jpeg")] to:mp3];
    XCTAssertEqualObjects(VibeSavedCover(mp3), (@[png, @"image/png"]), @"a PNG typed JPEG");

    NSURL *flac = [self write:@"audio.flac"];
    [self addPictures:@[front(bmp, nil)] to:flac];
    XCTAssertEqualObjects(VibeSavedCover(flac), (@[bmp, @"image/bmp"]), @"a BMP with no type");

    NSURL *m4a = [self write:@"audio.m4a"];
    [self addPictures:@[front(gif, @"image/jpeg")] to:m4a];
    XCTAssertEqualObjects(VibeSavedCover(m4a), (@[gif, @"image/gif"]), @"a GIF typed JPEG");

    NSURL *ogg = [self write:@"audio.ogg"];
    [self addPictures:@[front(unknown, @"Image/X-Vibe")] to:ogg];
    XCTAssertEqualObjects(VibeSavedCover(ogg), (@[unknown, @"image/x-vibe"]), @"bytes that name no type");
    [self assertFailure:ogg code:VibeTagWriteErrorInvalidImage write:^BOOL(NSError **error) {
        return VibeWriteFrontCover(ogg.path, unknown, @"image/x-vibe", error);
    }];

    NSURL *text = [_dir URLByAppendingPathComponent:@"text.flac"];
    [unknown writeToURL:text atomically:YES];
    NSError *error = nil;
    XCTAssertFalse(VibeTagLibReadPictures(text.path, NULL, NULL, &error));
    XCTAssertEqual(error.code, VibeTagWriteErrorNoParser);
}

#pragma mark - What a write leaves

// A custom field and a back cover beside whatever the file holds, written
// with TagLib itself, and an MP3's private frame.
- (void)addOthersTo:(NSURL *)url {
    [self addCustomTo:url];
    [self addPictures:@[[[VibeTagPicture alloc] initWithData:VibePNG(0.9) mimeType:@"image/png"
                                                        type:VibeTagPictureTypeBackCover description:nil]]
                   to:url];
}

- (void)addCustomTo:(NSURL *)url {
    TagLibAudioFile ref(url.fileSystemRepresentation, false, nil, 0, true);
    TagLib::File *file = ref.file();
    auto id3 = [](TagLib::ID3v2::Tag *tag) {
        tag->addFrame(new TagLib::ID3v2::UserTextIdentificationFrame("VIBE_CUSTOM", TagLib::StringList("kept"),
                                                                     TagLib::String::UTF8));
    };
    if (auto mpeg = dynamic_cast<TagLib::MPEG::File *>(file)) {
        const bool v3 = mpeg->hasID3v2Tag() && mpeg->ID3v2Tag()->header()->majorVersion() == 3;
        id3(mpeg->ID3v2Tag(true));
        auto priv = new TagLib::ID3v2::PrivateFrame();
        priv->setOwner("org.example.vibe");
        priv->setData(TagLib::ByteVector("opaque", 6));
        mpeg->ID3v2Tag()->addFrame(priv);
        XCTAssertTrue(mpeg->save(TagLib::MPEG::File::ID3v2, TagLib::File::StripNone,
                                 v3 ? TagLib::ID3v2::v3 : TagLib::ID3v2::v4));
    }
    else if (auto wav = dynamic_cast<TagLib::RIFF::WAV::File *>(file)) {
        id3(wav->ID3v2Tag());
        XCTAssertTrue(wav->save(TagLib::RIFF::WAV::File::ID3v2, TagLib::File::StripNone));
    }
    else if (auto aiff = dynamic_cast<TagLib::RIFF::AIFF::File *>(file)) {
        id3(aiff->tag());
        XCTAssertTrue(aiff->save());
    }
    else if (auto flac = dynamic_cast<TagLib::FLAC::File *>(file)) {
        flac->xiphComment(true)->addField("VIBE_CUSTOM", "kept");
        XCTAssertTrue(flac->save());
    }
    else if (auto xiph = dynamic_cast<TagLib::Ogg::XiphComment *>(file->tag())) {
        xiph->addField("VIBE_CUSTOM", "kept");
        XCTAssertTrue(file->save());
    }
    else if (auto mp4 = dynamic_cast<TagLib::MP4::File *>(file)) {
        mp4->tag()->setItem("----:com.apple.iTunes:VIBE_CUSTOM", TagLib::StringList("kept"));
        XCTAssertTrue(mp4->save());
    }
}

// A file with every field, a custom field, a front and a back cover. A write
// of the title and a removal of the composer change those alone.
- (void)testOneFieldLeavesEverythingElse {
    for (NSString *name in self.formats) {
        NSURL *url = [self write:name];
        XCTAssertTrue(VibeTagLibWriteTags(url.path, VibeEveryField(), YES, VibeJPEG(0.3), @"image/jpeg", VibeTagWriteSyncFull, NULL), @"%@", name);
        [self addOthersTo:url];
        VibeTagFieldValues *before = [self read:url];
        XCTAssertEqualObjects(before[@"VIBE_CUSTOM"], @[@"kept"], @"%@", name);
        NSArray<NSData *> *pictures = VibePictures(url);
        XCTAssertEqual(pictures.count, 2u, @"%@", name);
        NSData *audio = VibeDigest(url);
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
        XCTAssertEqualObjects(VibeDigest(url), audio, @"%@", name);
        TagLibAudioFile ref(url.fileSystemRepresentation);
        XCTAssertEqualObjects(audioMD5FromTagLibFile(ref.file()), md5, @"%@", name);
        if (auto mpeg = dynamic_cast<TagLib::MPEG::File *>(ref.file())) {
            XCTAssertEqual(mpeg->ID3v2Tag()->frameList("PRIV").size(), 1u, @"%@", name);
        }
    }
}

// Removing the front cover leaves the back cover, which the read then
// answers. In MP4, too, the removal takes the first entry alone.
- (void)testRemovingTheCoverLeavesOtherPictures {
    for (NSString *name in self.formats) {
        NSURL *url = [self write:name];
        XCTAssertTrue(VibeWriteFrontCover(url.path, VibeJPEG(0.5), @"image/jpeg", NULL), @"%@", name);
        [self addOthersTo:url];
        XCTAssertEqualObjects(VibeFrontCover(url), VibeJPEG(0.5), @"%@", name);
        XCTAssertTrue(VibeWriteFrontCover(url.path, nil, nil, NULL), @"%@", name);
        XCTAssertEqualObjects(VibePictures(url), @[VibePNG(0.9)], @"%@", name);
        XCTAssertEqualObjects(VibeFrontCover(url), VibePNG(0.9), @"%@", name);
    }
}

// An empty string removes, as an empty list does.
- (void)testAnEmptyValueRemovesInEveryFormat {
    for (NSString *name in self.formats) {
        NSURL *url = [self write:name];
        [self assertWrite:url fields:@{VibeTagFieldTitle: @[@"Title"], VibeTagFieldGenre: @[@"Jazz"]}];
        [self assertWrite:url fields:@{VibeTagFieldTitle: @[@""], VibeTagFieldGenre: @[@"", @""]}];
        VibeTagFieldValues *read = [self read:url];
        XCTAssertNil(read[VibeTagFieldTitle], @"%@", name);
        XCTAssertNil(read[VibeTagFieldGenre], @"%@", name);
    }
}

#pragma mark - Numbers and their other spellings

// A total alone keeps the number, and a number alone the total.
- (void)testANumberAndItsTotalKeepTheHalfNotNamed {
    for (NSString *name in self.formats) {
        NSURL *url = [self write:name];
        [self assertWrite:url fields:@{VibeTagFieldTrackNumber: @[@"3"], VibeTagFieldDiscNumber: @[@"1"],
                                       VibeTagFieldDiscTotal: @[@"2"]}];
        [self assertWrite:url fields:@{VibeTagFieldTrackTotal: @[@"12"], VibeTagFieldDiscTotal: @[]}];
        [self assertWrite:url fields:@{VibeTagFieldTrackNumber: @[@"4"]}];
        VibeTagFieldValues *read = [self read:url];
        XCTAssertEqualObjects(read[VibeTagFieldTrackNumber], @[@"4"], @"%@", name);
        XCTAssertEqualObjects(read[VibeTagFieldTrackTotal], @[@"12"], @"%@", name);
        XCTAssertEqualObjects(read[VibeTagFieldDiscNumber], @[@"1"], @"%@", name);
        XCTAssertNil(read[VibeTagFieldDiscTotal], @"%@", name);
    }
}

// Stale totals under other spellings, and a field's fallback spellings, go
// with a write of the field, so a removal sticks for media/Metadata's read.
- (void)testOtherSpellingsAreClearedInEveryFormat {
    for (NSString *name in self.formats) {
        NSURL *url = [self write:name];
        {
            TagLibAudioFile ref(url.fileSystemRepresentation, false, nil, 0, true);
            TagLib::File *file = ref.file();
            TagLib::PropertyMap stale;
            stale.insert("TRACKNUMBER", TagLib::StringList("3"));
            stale.insert("TRACKTOTAL", TagLib::StringList("9"));
            stale.insert("TOTALTRACKS", TagLib::StringList("8"));
            for (const char *key : {"DESCRIPTION", "ORGANIZATION", "PUBLISHER", "ORIGINALYEAR"}) {
                stale.insert(key, TagLib::StringList("stale"));
            }
            if (auto mpeg = dynamic_cast<TagLib::MPEG::File *>(file)) {
                const bool v3 = mpeg->hasID3v2Tag() && mpeg->ID3v2Tag()->header()->majorVersion() == 3;
                mpeg->ID3v2Tag(true)->setProperties(stale);
                XCTAssertTrue(mpeg->save(TagLib::MPEG::File::ID3v2, TagLib::File::StripNone,
                                         v3 ? TagLib::ID3v2::v3 : TagLib::ID3v2::v4));
            }
            else if (auto flac = dynamic_cast<TagLib::FLAC::File *>(file)) {
                flac->xiphComment(true)->setProperties(stale);
                XCTAssertTrue(flac->save());
            }
            else if (auto wav = dynamic_cast<TagLib::RIFF::WAV::File *>(file)) {
                wav->ID3v2Tag()->setProperties(stale);
                XCTAssertTrue(wav->save(TagLib::RIFF::WAV::File::ID3v2, TagLib::File::StripNone));
            }
            else {
                file->tag()->setProperties(stale);
                XCTAssertTrue(file->save());
            }
        }
        XCTAssertEqualObjects([self read:url][VibeTagFieldTrackTotal], @[@"9"], @"%@ reads the stale total", name);
        [self assertWrite:url fields:@{VibeTagFieldTrackTotal: @[], VibeTagFieldComment: @[], VibeTagFieldLabel: @[],
                                       VibeTagFieldOriginalDate: @[]}];
        TagLibAudioFile ref(url.fileSystemRepresentation, false);
        const TagLib::PropertyMap properties = ref.file()->properties();
        for (const char *key : {"TRACKTOTAL", "TOTALTRACKS", "DESCRIPTION", "ORGANIZATION", "PUBLISHER",
                                "ORIGINALYEAR"}) {
            XCTAssertFalse(properties.contains(key), @"%@ %s", name, key);
        }
        XCTAssertEqual(properties.value("TRACKNUMBER"), TagLib::StringList("3"), @"%@", name);
        XCTAssertNil([self read:url][VibeTagFieldTrackTotal], @"%@", name);
    }
}

// An MP3 with ID3v2 and ID3v1: ID3v1 takes the number alone and the year.
- (void)testID3v1TakesTheNumberAndTheYear {
    NSURL *url = [_dir URLByAppendingPathComponent:@"both.mp3"];
    XCTAssertTrue([VibeMP3WithInfoFrame(38, YES) writeToURL:url atomically:YES]);
    [self assertWrite:url fields:@{VibeTagFieldTitle: @[@"Title"], VibeTagFieldTrackNumber: @[@"3"],
                                   VibeTagFieldTrackTotal: @[@"12"], VibeTagFieldDate: @[@"2001-02-03"]}];
    TagLib::MPEG::File file(url.fileSystemRepresentation);
    XCTAssertTrue(file.hasID3v1Tag());
    XCTAssertEqual(file.ID3v1Tag()->track(), 3u);
    XCTAssertEqual(file.ID3v1Tag()->year(), 2001u);
    XCTAssertEqual(file.ID3v1Tag()->title(), TagLib::String("Title"));
    XCTAssertEqual(file.ID3v2Tag()->properties().value("TRACKNUMBER"), TagLib::StringList("3/12"));
    XCTAssertEqual(file.ID3v2Tag()->properties().value("DATE"), TagLib::StringList("2001-02-03"));
}

// MP4's numbers are whole numbers from 0 to 65535.
- (void)testMP4RefusesANumberItCannotHold {
    NSURL *url = [self write:@"audio.m4a"];
    for (NSDictionary *fields in @[@{VibeTagFieldTrackNumber: @[@"A1"]}, @{VibeTagFieldTrackNumber: @[@"70000"]},
                                   @{VibeTagFieldTrackTotal: @[@"x"]}, @{VibeTagFieldDiscNumber: @[@"1/B"]},
                                   @{VibeTagFieldBPM: @[@"128.5"]}, @{VibeTagFieldCompilation: @[@"yes"]},
                                   @{VibeTagFieldBPM: @[@"120", @"121"]}]) {
        [self assertFailure:url code:VibeTagWriteErrorUnsupportedValue fields:fields];
    }
}

#pragma mark - ID3v2

// ID3v2.3 holds a year as the original date, and a date to the minute.
- (void)testID3v23RefusesADateItCannotHold {
    NSURL *url = [self write:@"id3v23.mp3"];
    [self assertFailure:url code:VibeTagWriteErrorUnsupportedValue
                 fields:@{VibeTagFieldOriginalDate: @[@"1999-05-01"]}];
    [self assertFailure:url code:VibeTagWriteErrorUnsupportedValue fields:@{VibeTagFieldDate: @[@"2001-02"]}];
}

- (NSURL *)mp3WithTag:(NSData *)tag name:(NSString *)name {
    NSURL *url = [_dir URLByAppendingPathComponent:name];
    NSMutableData *bytes = [tag mutableCopy];
    [bytes appendData:VibeMP3WithInfoFrame(38, NO)];
    XCTAssertTrue([bytes writeToURL:url atomically:YES]);
    return url;
}

// A Latin-1 text frame's body.
static NSData *VibeText(const char *text) {
    NSMutableData *body = [NSMutableData dataWithLength:1];
    [body appendBytes:text length:strlen(text)];
    return body;
}

// TRAP: TagLib's ID3v2.3 render keeps one genre with no ID3v1 number, so a
// title edit would lose the other.
- (void)testID3v23WithTwoNamedGenresRefuses {
    NSData *genres = [NSData dataWithBytes:"\0Deep House\0Tech House" length:22];
    NSMutableData *frames = [VibeID3v2Frame("TIT2", 3, 6, 0, VibeText("Title")) mutableCopy];
    [frames appendData:VibeID3v2Frame("TCON", 3, (uint32_t)genres.length, 0, genres)];
    NSURL *url = [self mp3WithTag:VibeID3v2Tag(3, 0, frames) name:@"genres.mp3"];
    XCTAssertEqualObjects([self read:url][VibeTagFieldGenre], (@[@"Deep House", @"Tech House"]));
    [self assertFailure:url code:VibeTagWriteErrorWouldLoseData fields:@{VibeTagFieldTitle: @[@"New"]}];
    // A write of the genre itself, to one, goes through.
    [self assertWrite:url fields:@{VibeTagFieldGenre: @[@"Deep House"]}];
    XCTAssertEqualObjects([self read:url][VibeTagFieldGenre], @[@"Deep House"]);
}

// mp3gain's RVAD, and the other frames TagLib's parse marks to discard,
// would go at any save. TagLib's own save drops it, as the copy shows, so
// the writer refuses.
- (void)testID3v23FramesTagLibDropsRefuse {
    NSData *rvad = [NSData dataWithBytes:"\x03\x10\x00\x10\x00\x10\x00\x00\x00\x00" length:10];
    NSMutableData *frames = [VibeID3v2Frame("TIT2", 3, 6, 0, VibeText("Title")) mutableCopy];
    [frames appendData:VibeID3v2Frame("RVAD", 3, (uint32_t)rvad.length, 0, rvad)];
    NSURL *url = [self mp3WithTag:VibeID3v2Tag(3, 0, frames) name:@"rvad.mp3"];
    NSURL *copy = [_dir URLByAppendingPathComponent:@"rvad-taglib.mp3"];
    XCTAssertTrue([NSFileManager.defaultManager copyItemAtURL:url toURL:copy error:NULL]);
    {
        TagLib::MPEG::File file(copy.fileSystemRepresentation);
        file.ID3v2Tag()->setTitle("New");
        XCTAssertTrue(file.save(TagLib::MPEG::File::ID3v2, TagLib::File::StripNone, TagLib::ID3v2::v3));
    }
    NSData *saved = [NSData dataWithContentsOfURL:copy];
    XCTAssertEqual([saved rangeOfData:[@"RVAD" dataUsingEncoding:NSASCIIStringEncoding] options:0
                                range:NSMakeRange(0, saved.length)].location, (NSUInteger)NSNotFound);
    [self assertFailure:url code:VibeTagWriteErrorWouldLoseData fields:@{VibeTagFieldTitle: @[@"New"]}];
}

// TRAP: with no zlib, a compressed frame would be written back as a plain
// one holding compressed bytes. Compressed and encrypted frames refuse, the
// cover too.
- (void)testACompressedOrEncryptedFrameRefuses {
    NSData *body = [NSData dataWithBytes:"\x00\x00\x00\x10" "compressed bytes" length:20];
    for (NSNumber *flag in @[@0x80, @0x40]) {
        NSMutableData *frames = [VibeID3v2Frame("TIT2", 3, 6, 0, VibeText("Title")) mutableCopy];
        [frames appendData:VibeID3v2Frame("APIC", 3, (uint32_t)body.length, flag.unsignedCharValue, body)];
        NSURL *url = [self mp3WithTag:VibeID3v2Tag(3, 0, frames)
                                 name:[NSString stringWithFormat:@"flag-%@.mp3", flag]];
        [self assertFailure:url code:VibeTagWriteErrorUnsupportedFrame fields:@{VibeTagFieldTitle: @[@"New"]}];
        [self assertFailure:url code:VibeTagWriteErrorUnsupportedFrame write:^BOOL(NSError **error) {
            return VibeWriteFrontCover(url.path, nil, nil, error);
        }];
    }
}

// media/Metadata reads TIT1 as the grouping when GRP1 is absent.
- (void)testRemovingTheGroupingRemovesTheTIT1ItShowed {
    NSMutableData *frames = [VibeID3v2Frame("TIT1", 4, 6, 0, VibeText("Group")) mutableCopy];
    NSURL *url = [self mp3WithTag:VibeID3v2Tag(4, 0, frames) name:@"tit1.mp3"];
    [self assertWrite:url fields:@{VibeTagFieldGrouping: @[]}];
    XCTAssertNil([self read:url][@"WORK"]);
    [frames appendData:VibeID3v2Frame("GRP1", 4, 6, 0, VibeText("Other"))];
    NSURL *both = [self mp3WithTag:VibeID3v2Tag(4, 0, frames) name:@"both.mp3"];
    [self assertFailure:both code:VibeTagWriteErrorWouldLoseData fields:@{VibeTagFieldGrouping: @[]}];
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

#pragma mark - WAV's INFO

// The bytes of the file's LIST INFO chunk, header and all, or nil.
static NSData *VibeInfoChunk(NSURL *url) {
    NSData *data = [NSData dataWithContentsOfURL:url];
    const uint8_t *b = (const uint8_t *)data.bytes;
    for (NSUInteger at = 12; at + 12 <= data.length;) {
        uint32_t size;
        memcpy(&size, b + at + 4, 4);
        if (memcmp(b + at, "LIST", 4) == 0 && memcmp(b + at + 8, "INFO", 4) == 0) {
            return [data subdataWithRange:NSMakeRange(at, MIN(data.length - at, 8 + (NSUInteger)size))];
        }
        at += 8 + size + (size & 1);
    }
    return nil;
}

static NSString *const kVibeLatin1Artist = @"Café Artist";

// A WAV with an INFO chunk of Latin-1 text, as Windows tools write it.
- (NSURL *)latin1InfoWAV {
    NSURL *url = [self write:@"latin1.wav"];
    NSMutableData *info = [NSMutableData dataWithBytes:"INFO" length:4];
    for (NSArray<NSString *> *field in @[@[@"IART", kVibeLatin1Artist], @[@"INAM", @"Old"]]) {
        NSData *text = [field[1] dataUsingEncoding:NSISOLatin1StringEncoding];
        const uint32_t size = (uint32_t)text.length + 1;
        [info appendData:[field[0] dataUsingEncoding:NSASCIIStringEncoding]];
        [info appendBytes:&size length:4];
        [info appendData:text];
        [info increaseLengthBy:1 + (size & 1)];
    }
    NSMutableData *file = [NSMutableData dataWithContentsOfURL:url];
    const uint32_t size = (uint32_t)info.length;
    [file appendBytes:"LIST" length:4];
    [file appendBytes:&size length:4];
    [file appendData:info];
    const uint32_t riff = (uint32_t)file.length - 8;
    [file replaceBytesInRange:NSMakeRange(4, 4) withBytes:&riff];
    XCTAssertTrue([file writeToURL:url atomically:YES]);
    return url;
}

// TRAP: TagLib renders INFO text as UTF-8. An INFO chunk is rewritten only
// when the edit changes it, and its untouched values keep their bytes.
- (void)testINFOKeepsItsBytes {
    NSURL *url = [self latin1InfoWAV];
    NSData *info = VibeInfoChunk(url);
    XCTAssertNotNil(info);
    XCTAssertEqualObjects([self read:url][VibeTagFieldArtist], @[kVibeLatin1Artist]);
    XCTAssertTrue(VibeWriteFrontCover(url.path, VibeJPEG(0.4), @"image/jpeg", NULL));
    XCTAssertEqualObjects(VibeInfoChunk(url), info, @"a cover write leaves INFO");
    [self assertWrite:url fields:@{VibeTagFieldTitle: @[@"New"]}];
    NSData *rewritten = VibeInfoChunk(url);
    NSData *latin1 = [kVibeLatin1Artist dataUsingEncoding:NSISOLatin1StringEncoding];
    XCTAssertNotEqual([rewritten rangeOfData:latin1 options:0 range:NSMakeRange(0, rewritten.length)].location,
                      (NSUInteger)NSNotFound, @"the artist stays Latin-1");
    XCTAssertNotEqual([rewritten rangeOfData:[NSData dataWithBytes:"INAM\x04\0\0\0New" length:11] options:0
                                       range:NSMakeRange(0, rewritten.length)].location,
                      (NSUInteger)NSNotFound, @"the title is the edit");
}

#pragma mark - The cover

- (void)testACoverMustBeWhatItsTypeSays {
    NSURL *url = [self write:@"audio.flac"];
    NSMutableData *big = [NSMutableData dataWithLength:16000001];
    memcpy(big.mutableBytes, "\xFF\xD8\xFF", 3);
    // Each type cut short, or with zeros where its tail never arrived, a BMP
    // header of no known size, and a WebP whose RIFF runs past its bytes.
    NSMutableArray *cut = [NSMutableArray array];
    for (NSString *mime in @[@"image/jpeg", @"image/png", @"image/gif", @"image/bmp", @"image/webp"]) {
        NSData *whole = VibeImageOfType(mime, 0);
        NSData *shorter = [whole subdataWithRange:NSMakeRange(0, whole.length - 3)];
        NSMutableData *zeros = [shorter mutableCopy];
        [zeros increaseLengthBy:3];
        [cut addObject:@[shorter, mime]];
        // BMP and WebP end in no marker, so zeros there are pixels.
        if (![mime isEqualToString:@"image/webp"] && ![mime isEqualToString:@"image/bmp"]) {
            [cut addObject:@[zeros, mime]];
        }
    }
    NSMutableData *bmp = [VibeImageOfType(@"image/bmp", 0) mutableCopy];
    ((uint8_t *)bmp.mutableBytes)[14] = 99;
    [cut addObject:@[bmp, @"image/bmp"]];
    NSArray *refused = @[@[VibePNG(0.1), @"image/jpeg"], @[VibeJPEG(0.1), @"image/png"], @[big, @"image/jpeg"],
                         @[[NSData data], @"image/png"], @[VibeJPEG(0.1), @"image/gif"]];
    for (NSArray *cover in [refused arrayByAddingObjectsFromArray:cut]) {
        [self assertFailure:url code:VibeTagWriteErrorInvalidImage write:^BOOL(NSError **error) {
            return VibeWriteFrontCover(url.path, cover[0], cover[1], error);
        }];
    }
}

#pragma mark - Refusals of a file's own shape

// TRAP: FLAC's save renders its ID3v2 tag as 2.4 and copies its fields into
// the Vorbis comment, so a FLAC with ID3 tags refuses.
- (void)testAFLACWithID3TagsRefuses {
    NSURL *flac = [self write:@"audio.flac"];
    NSMutableData *bytes = [VibeID3v2Tag(3, 0, VibeID3v2Frame("TIT2", 3, 6, 0, VibeText("Title"))) mutableCopy];
    [bytes appendData:[NSData dataWithContentsOfURL:flac]];
    NSURL *url = [_dir URLByAppendingPathComponent:@"id3.flac"];
    XCTAssertTrue([bytes writeToURL:url atomically:YES]);
    [self assertFailure:url code:VibeTagWriteErrorWouldLoseData fields:@{VibeTagFieldTitle: @[]}];
}

// TRAP: TagLib's MP4 save rewrites ilst from what it parsed, so an item it
// could not parse refuses.
- (void)testAnMP4ItemTagLibCannotParseRefuses {
    NSURL *url = [self write:@"audio.m4a"];
    [self assertWrite:url fields:@{VibeTagFieldTitle: @[@"Title"], VibeTagFieldArtist: @[@"Artist"]}];
    NSMutableData *bytes = [NSMutableData dataWithContentsOfURL:url];
    const NSRange name = [bytes rangeOfData:[NSData dataWithBytes:"\xA9nam" length:4] options:0
                                      range:NSMakeRange(0, bytes.length)];
    XCTAssertNotEqual(name.location, (NSUInteger)NSNotFound);
    // The title's data atom renamed, so TagLib no longer parses the item.
    [bytes replaceBytesInRange:NSMakeRange(name.location + 8, 4) withBytes:"dat0"];
    XCTAssertTrue([bytes writeToURL:url atomically:YES]);
    XCTAssertNil([self read:url][VibeTagFieldTitle]);
    [self assertFailure:url code:VibeTagWriteErrorWouldLoseData fields:@{VibeTagFieldArtist: @[@"New"]}];
}

#pragma mark - The digest

// The digest changes with an audio byte, and not with a tag write that
// grows the tag and moves the audio.
- (void)testTheDigestFollowsTheAudioInEveryFormat {
    NSString *title = [@"" stringByPaddingToLength:5000 withString:@"x" startingAtIndex:0];
    for (NSString *name in self.formats) {
        NSURL *url = [self write:name];
        NSData *digest = VibeDigest(url);
        XCTAssertNotNil(digest, @"%@", name);
        [self assertWrite:url fields:@{VibeTagFieldTitle: @[title]}];
        XCTAssertEqualObjects(VibeDigest(url), digest, @"%@: a tag that grows", name);
        NSMutableData *bytes = [NSMutableData dataWithContentsOfURL:url];
        // The audio's own chunk where the tag's may follow it.
        NSDictionary<NSString *, NSString *> *chunks = @{@"m4a": @"mdat", @"wav": @"data", @"aif": @"SSND"};
        NSString *chunk = chunks[name.pathExtension];
        NSUInteger at = bytes.length - 1;
        if (chunk) {
            at = [bytes rangeOfData:[chunk dataUsingEncoding:NSASCIIStringEncoding] options:0
                              range:NSMakeRange(0, bytes.length)].location + 100;
        }
        ((uint8_t *)bytes.mutableBytes)[at] ^= 0x01;
        XCTAssertTrue([bytes writeToURL:url atomically:YES]);
        XCTAssertNotEqualObjects(VibeDigest(url), digest, @"%@: an audio byte", name);
    }
}

#pragma mark - The audio match

// The match agrees with the digest on every case the digest's test covers,
// and on a one-bit change, a cut tail, and two formats.
- (void)testTheMatchAgreesWithTheDigest {
    NSString *title = [@"" stringByPaddingToLength:5000 withString:@"x" startingAtIndex:0];
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *flac = nil;
    for (NSString *name in self.formats) {
        NSURL *original = [self write:name];
        if ([name isEqualToString:@"audio.flac"]) flac = original;
        NSURL *copy = [_dir URLByAppendingPathComponent:[@"copy-" stringByAppendingString:name]];
        XCTAssertTrue([files copyItemAtURL:original toURL:copy error:NULL]);
        [self assertWrite:copy fields:@{VibeTagFieldTitle: @[title]}];
        [self assertMatch:original with:copy name:name];

        NSMutableData *bytes = [NSMutableData dataWithContentsOfURL:copy];
        NSDictionary<NSString *, NSString *> *chunks = @{@"m4a": @"mdat", @"wav": @"data", @"aif": @"SSND"};
        NSString *chunk = chunks[name.pathExtension];
        NSUInteger at = bytes.length - 1;
        if (chunk) {
            at = [bytes rangeOfData:[chunk dataUsingEncoding:NSASCIIStringEncoding] options:0
                              range:NSMakeRange(0, bytes.length)].location + 100;
        }
        NSMutableData *flipped = [bytes mutableCopy];
        ((uint8_t *)flipped.mutableBytes)[at] ^= 0x01;
        XCTAssertTrue([flipped writeToURL:copy atomically:YES]);
        [self assertMatch:original with:copy name:[name stringByAppendingString:@" one bit"]];

        // A WAV's or AIFF's tag follows its audio, so the cut reaches into the audio.
        NSData *cut = [bytes subdataWithRange:NSMakeRange(0, chunk ? at + 200 : bytes.length - 300)];
        XCTAssertTrue([cut writeToURL:copy atomically:YES]);
        [self assertMatch:original with:copy name:[name stringByAppendingString:@" cut"]];
    }
    NSURL *wav = [_dir URLByAppendingPathComponent:@"audio.wav"];
    [self assertMatch:flac with:wav name:@"two formats"];
    NSError *error = nil;
    XCTAssertFalse(VibeTagLibAudioMatches(flac.path, [_dir URLByAppendingPathComponent:@"missing.wav"].path, &error));
    XCTAssertEqual(error.code, VibeTagWriteErrorOpenFailed);
}

// The match answers what the digests do: YES for equal digests, AudioDiffers
// for unequal ones, and the digest's own error when one has none.
- (void)assertMatch:(NSURL *)a with:(NSURL *)b name:(NSString *)name {
    NSError *digestError = nil, *matchError = nil;
    NSData *digestA = VibeTagLibAudioDigest(a.path, NULL), *digestB = VibeTagLibAudioDigest(b.path, &digestError);
    XCTAssertNotNil(digestA, @"%@", name);
    const BOOL matches = VibeTagLibAudioMatches(a.path, b.path, &matchError);
    if (!digestB) {
        XCTAssertFalse(matches, @"%@", name);
        XCTAssertEqual(matchError.code, digestError.code, @"%@: %@", name, matchError);
    }
    else if ([digestA isEqualToData:digestB]) {
        XCTAssertTrue(matches, @"%@: %@", name, matchError);
    }
    else {
        XCTAssertFalse(matches, @"%@", name);
        XCTAssertEqual(matchError.code, VibeTagWriteErrorAudioDiffers, @"%@: %@", name, matchError);
    }
    XCTAssertEqual(VibeTagLibAudioMatches(b.path, a.path, NULL), matches, @"%@ both ways", name);
    if ([name hasSuffix:@"one bit"] || [name hasSuffix:@"cut"]
            || [name isEqualToString:@"two formats"]) {
        XCTAssertFalse(matches, @"%@ differs", name);
    }
    else {
        XCTAssertTrue(matches, @"%@ matches", name);
    }
}

// The same file named twice, by its path or by a hard link, is an error,
// not a match.
- (void)testTheMatchRefusesOneFileTwice {
    NSURL *url = [self write:@"audio.flac"];
    NSURL *hard = [_dir URLByAppendingPathComponent:@"link.flac"];
    XCTAssertEqual(link(url.fileSystemRepresentation, hard.fileSystemRepresentation), 0);
    for (NSURL *other in @[url, hard]) {
        NSError *error = nil;
        XCTAssertFalse(VibeTagLibAudioMatches(url.path, other.path, &error));
        XCTAssertEqual(error.code, VibeTagWriteErrorSameFile, @"%@", error);
    }
}

// TRAP: a plain WAV whose data chunk is 0 bytes, or 0xFFFFFFFF from a writer
// that never finished, and an MP4 sound track with no samples, as a
// fragmented MP4's is, hold no audio to check. The digest and the match
// answer that the audio is not found.
- (void)testAudioWithNoSamplesIsNotFound {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (NSNumber *size in @[@0u, @0xFFFFFFFFu]) {
        NSURL *wav = [self write:[NSString stringWithFormat:@"empty-%@.wav", size]];
        NSMutableData *bytes = [NSMutableData dataWithContentsOfURL:wav];
        const NSRange data = [bytes rangeOfData:[@"data" dataUsingEncoding:NSASCIIStringEncoding] options:0
                                          range:NSMakeRange(0, bytes.length)];
        const uint32_t value = size.unsignedIntValue;
        [bytes replaceBytesInRange:NSMakeRange(data.location + 4, 4) withBytes:&value];
        XCTAssertTrue([bytes writeToURL:wav atomically:YES]);
        [urls addObject:wav];
    }
    NSURL *m4a = [self write:@"empty.m4a"];
    NSMutableData *bytes = [NSMutableData dataWithContentsOfURL:m4a];
    const NSRange stsz = [bytes rangeOfData:[@"stsz" dataUsingEncoding:NSASCIIStringEncoding] options:0
                                      range:NSMakeRange(0, bytes.length)];
    XCTAssertNotEqual(stsz.location, (NSUInteger)NSNotFound);
    // stsz: its version and flags, a size for every sample, then the count.
    const uint32_t none = 0;
    [bytes replaceBytesInRange:NSMakeRange(stsz.location + 8, 4) withBytes:&none];
    [bytes replaceBytesInRange:NSMakeRange(stsz.location + 12, 4) withBytes:&none];
    XCTAssertTrue([bytes writeToURL:m4a atomically:YES]);
    [urls addObject:m4a];
    NSURL *flac = [self write:@"audio.flac"];
    for (NSURL *url in urls) {
        NSError *error = nil;
        XCTAssertNil(VibeTagLibAudioDigest(url.path, &error), @"%@", url.lastPathComponent);
        XCTAssertEqual(error.code, VibeTagWriteErrorNoParser, @"%@: %@", url.lastPathComponent, error);
        error = nil;
        XCTAssertFalse(VibeTagLibAudioMatches(flac.path, url.path, &error), @"%@", url.lastPathComponent);
        XCTAssertEqual(error.code, VibeTagWriteErrorNoParser, @"%@: %@", url.lastPathComponent, error);
    }
}

// A file cut short while the match reads it is an error. Mapped, the read
// past its new end raised SIGBUS and ended the process.
- (void)testTheMatchSurvivesAFileCutShortWhileItReads {
    NSString *a = [_dir.path stringByAppendingPathComponent:@"long-a.wav"];
    NSString *b = [_dir.path stringByAppendingPathComponent:@"long-b.wav"];
    const uint64_t size = 256ull << 20;
    VibeWriteLargeAudio(a, @"wav", size, 0);
    BOOL cutWhileReading = NO;
    for (int attempt = 0; attempt < 5 && !cutWhileReading; attempt++) {
        [NSFileManager.defaultManager removeItemAtPath:b error:NULL];
        XCTAssertTrue([NSFileManager.defaultManager copyItemAtPath:a toPath:b error:NULL]);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 + 10 * attempt) * NSEC_PER_MSEC),
                       dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            truncate(b.fileSystemRepresentation, (off_t)(size / 2));
        });
        NSError *error = nil;
        const BOOL matches = VibeTagLibAudioMatches(a, b, &error);
        [NSThread sleepForTimeInterval:0.1];
        if (matches) continue;  // the cut came after the read
        XCTAssertTrue(error.code == VibeTagWriteErrorReadFailed || error.code == VibeTagWriteErrorAudioDiffers,
                      @"%@", error);
        cutWhileReading = error.code == VibeTagWriteErrorReadFailed;
    }
    XCTAssertTrue(cutWhileReading, @"no cut landed while the match read");
}

#pragma mark - The sync

// TRAP: a drive that ignores barriers still answers success, so a barrier
// is taken only on an APFS volume in the boot disk's container. A file on
// an APFS disk image, local and in a container of its own, gets the full
// flush.
- (void)testABarrierTakesOnlyTheBootContainer {
    NSURL *local = [_dir URLByAppendingPathComponent:@"local.bin"];
    XCTAssertTrue([[NSData dataWithBytes:"x" length:1] writeToURL:local atomically:NO]);
    const int localFD = open(local.fileSystemRepresentation, O_RDONLY);
    XCTAssertTrue(VibeVolumeOrdersBarriers(localFD), @"the temporary folder is on the boot container");
    close(localFD);
    {
        VibeCheckedFileStream stream(local.fileSystemRepresentation);
        stream.writeBlock(TagLib::ByteVector("abc", 3));
        XCTAssertTrue(stream.finish(VibeCheckedFileStream::Sync::Barrier));
        XCTAssertEqual((int)stream.synced(), (int)VibeCheckedFileStream::Sync::Barrier);
    }
    NSString *image = [_dir.path stringByAppendingPathComponent:@"apfs.dmg"];
    NSString *mount = [_dir.path stringByAppendingPathComponent:@"mount"];
    if (VibeRun(@[@"/usr/bin/hdiutil", @"create", @"-size", @"16m", @"-fs", @"APFS", @"-volname", @"VibeBarrier",
                  @"-quiet", image]) != 0
            || VibeRun(@[@"/usr/bin/hdiutil", @"attach", @"-nobrowse", @"-quiet", @"-mountpoint", mount, image]) != 0) {
        XCTSkip(@"hdiutil could not make and attach an APFS disk image");
    }
    [self addTeardownBlock:^{
        VibeRun(@[@"/usr/bin/hdiutil", @"detach", @"-quiet", @"-force", mount]);
    }];
    NSString *path = [mount stringByAppendingPathComponent:@"file.bin"];
    XCTAssertTrue([[NSData dataWithBytes:"x" length:1] writeToFile:path atomically:NO]);
    const int fd = open(path.fileSystemRepresentation, O_RDONLY);
    XCTAssertFalse(VibeVolumeOrdersBarriers(fd));
    close(fd);
    {
        VibeCheckedFileStream stream(path.fileSystemRepresentation);
        stream.writeBlock(TagLib::ByteVector("abc", 3));
        XCTAssertTrue(stream.finish(VibeCheckedFileStream::Sync::Barrier));
        XCTAssertEqual((int)stream.synced(), (int)VibeCheckedFileStream::Sync::Full);
    }
}

// A write that asks for a barrier writes as the default does.
- (void)testABarrierWriteRoundTrips {
    for (NSString *name in self.formats) {
        NSURL *url = [self write:name];
        NSData *audio = VibeDigest(url);
        NSError *error = nil;
        XCTAssertTrue(VibeTagLibWriteTags(url.path, @{VibeTagFieldTitle: @[@"Barrier"]}, YES, VibePNG(0.5),
                                                  @"image/png", VibeTagWriteSyncBarrier, &error),
                      @"%@: %@", name, error);
        XCTAssertEqualObjects([self read:url][VibeTagFieldTitle], @[@"Barrier"], @"%@", name);
        XCTAssertEqualObjects(VibeFrontCover(url), VibePNG(0.5), @"%@", name);
        XCTAssertEqualObjects(VibeDigest(url), audio, @"%@", name);
    }
}

#pragma mark - Measurements

// Run by hand, with TEST_RUNNER_VIBE_TAG_MEASURE=1: 200 writes each way, and
// the digest against the match on a large FLAC and WAV. A copy holds the
// same audio behind a larger tag, so its audio starts elsewhere.
// Run by hand as the one below: 200 matches of a small FLAC and its tagged
// copy, the cost a many-file edit pays per file.
- (void)testMeasureSmallMatches {
    if (!NSProcessInfo.processInfo.environment[@"VIBE_TAG_MEASURE"]) {
        XCTSkip(@"set VIBE_TAG_MEASURE to measure");
    }
    NSURL *url = [self write:@"audio.flac"];
    NSURL *copy = [_dir URLByAppendingPathComponent:@"copy.flac"];
    XCTAssertTrue([NSFileManager.defaultManager copyItemAtURL:url toURL:copy error:NULL]);
    [self assertWrite:copy fields:@{VibeTagFieldTitle: @[@"Copy"]}];
    for (int pass = 0; pass < 3; pass++) {
        const CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
        for (int i = 0; i < 200; i++) XCTAssertTrue(VibeTagLibAudioMatches(url.path, copy.path, NULL));
        NSLog(@"VIBE_MEASURE 200 small matches pass %d: %.3f s", pass, CFAbsoluteTimeGetCurrent() - start);
    }
}

- (void)testMeasureTheSyncAndTheMatch {
    if (!NSProcessInfo.processInfo.environment[@"VIBE_TAG_MEASURE"]) {
        XCTSkip(@"set VIBE_TAG_MEASURE to measure");
    }
    NSURL *url = [self write:@"audio.flac"];
    for (NSNumber *sync in @[@(VibeTagWriteSyncFull), @(VibeTagWriteSyncBarrier), @(VibeTagWriteSyncFull),
                             @(VibeTagWriteSyncBarrier)]) {
        const CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
        for (int i = 0; i < 200; i++) {
            NSString *title = [NSString stringWithFormat:@"Title %d", i];
            XCTAssertTrue(VibeTagLibWriteTags(url.path, @{VibeTagFieldTitle: @[title]}, NO, nil, nil,
                                                      (VibeTagWriteSync)sync.integerValue, NULL));
        }
        NSLog(@"VIBE_MEASURE 200 writes %@: %.3f s", sync.integerValue ? @"barrier" : @"full",
              CFAbsoluteTimeGetCurrent() - start);
    }
    const uint64_t size = 2ull << 30;
    NSString *root = NSProcessInfo.processInfo.environment[@"VIBE_TAG_MEASURE_DIR"] ?: _dir.path;
    for (NSString *kind in @[@"flac", @"wav"]) {
        NSString *a = [root stringByAppendingPathComponent:[@"large-a." stringByAppendingString:kind]];
        NSString *b = [root stringByAppendingPathComponent:[@"large-b." stringByAppendingString:kind]];
        VibeWriteLargeAudio(a, kind, size, 0);
        VibeWriteLargeAudio(b, kind, size, 64 * 1024);
        for (int pass = 0; pass < 2; pass++) {
            const uint64_t before = VibeFootprint();
            CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
            @autoreleasepool {
                NSData *da = VibeTagLibAudioDigest(a, NULL), *db = VibeTagLibAudioDigest(b, NULL);
                XCTAssertEqualObjects(da, db);
            }
            const CFAbsoluteTime digest = CFAbsoluteTimeGetCurrent() - start;
            start = CFAbsoluteTimeGetCurrent();
            uint64_t peak = 0;
            @autoreleasepool {
                XCTAssertTrue(VibeTagLibAudioMatches(a, b, NULL));
                peak = VibeFootprint();
            }
            const CFAbsoluteTime match = CFAbsoluteTimeGetCurrent() - start;
            NSLog(@"VIBE_MEASURE %@ 2 GiB pass %d: two digests %.3f s, match %.3f s, footprint +%.1f MB", kind, pass,
                  digest, match, ((double)peak - (double)before) / 1e6);
        }
        NSFileHandle *handle = [NSFileHandle fileHandleForUpdatingAtPath:b];
        [handle seekToFileOffset:size + 64 * 1024 - 1000];
        [handle writeData:[NSData dataWithBytes:"\x5A\xA5" length:2]];
        [handle closeFile];
        CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
        XCTAssertFalse(VibeTagLibAudioMatches(a, b, NULL));
        NSLog(@"VIBE_MEASURE %@ 2 GiB, a byte near the end: match %.3f s", kind, CFAbsoluteTimeGetCurrent() - start);
        [NSFileManager.defaultManager removeItemAtPath:a error:NULL];
        [NSFileManager.defaultManager removeItemAtPath:b error:NULL];
    }
}

#pragma mark - Failures

// A write past the file size limit fails, where TagLib's own stream answers
// success: the cover grows the tag, the file's tail must move, and the
// first write past the limit fails.
- (void)testAFailedWriteFails {
    NSURL *url = [self write:@"plain.mp3"];
    NSNumber *size = nil;
    [url getResourceValue:&size forKey:NSURLFileSizeKey error:NULL];
    NSMutableData *cover = [VibeJPEG(0.6) mutableCopy];
    [cover increaseLengthBy:200000];
    struct rlimit before;
    getrlimit(RLIMIT_FSIZE, &before);
    void (*handler)(int) = signal(SIGXFSZ, SIG_IGN);
    struct rlimit limit = before;
    limit.rlim_cur = size.unsignedLongLongValue + 1000;
    setrlimit(RLIMIT_FSIZE, &limit);
    NSError *error = nil;
    const BOOL wrote = VibeWriteFrontCover(url.path, cover, @"image/jpeg", &error);
    setrlimit(RLIMIT_FSIZE, &before);
    signal(SIGXFSZ, handler);
    XCTAssertFalse(wrote);
    XCTAssertEqual(error.code, VibeTagWriteErrorSaveFailed, @"%@", error);
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
    XCTAssertFalse(VibeWriteFields(url.path, @{VibeTagFieldTitle: @[@"Title"]}, &error));
    XCTAssertEqual(error.code, VibeTagWriteErrorOpenFailed);
}

// A metadata block, an atom, or a page that runs past the file, and bytes no
// parser takes: no parser takes the file, and its bytes stay.
- (void)testADamagedFileFailsAndKeepsItsBytes {
    NSURL *flac = [self write:@"damaged.flac"];
    NSMutableData *bytes = [NSMutableData dataWithContentsOfURL:flac];
    uint8_t *b = (uint8_t *)bytes.mutableBytes;
    b[4] &= 0x80;
    b[5] = 0xFF; b[6] = 0xFF; b[7] = 0xFF;
    [bytes writeToURL:flac atomically:YES];

    NSURL *m4a = [self write:@"damaged.m4a"];
    NSURL *cut = [_dir URLByAppendingPathComponent:@"cut.m4a"];
    [[[NSData dataWithContentsOfURL:m4a] subdataWithRange:NSMakeRange(0, 40)] writeToURL:cut atomically:YES];

    NSURL *ogg = [_dir URLByAppendingPathComponent:@"damaged.opus"];
    NSMutableData *opus = [VibeOggTagFile(YES) mutableCopy];
    memcpy((uint8_t *)opus.mutableBytes + 28, "OpusJunk", 8);
    [opus writeToURL:ogg atomically:YES];

    NSURL *text = [_dir URLByAppendingPathComponent:@"text.mp3"];
    [[@"not audio at all" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:text atomically:YES];

    for (NSURL *url in @[flac, cut, ogg, text]) {
        [self assertFailure:url code:VibeTagWriteErrorNoParser fields:@{VibeTagFieldTitle: @[@"Title"]}];
    }
}

// Only the fields this API edits: TagLib's other keys would add duplicate
// frames, or write a picture as text.
- (void)testOnlyTheEditedFieldsAreTaken {
    NSURL *url = [self write:@"audio.flac"];
    for (NSString *key in @[@"", @"LYRICS", @"URL", @"MUSICBRAINZ_TRACKID", @"METADATA_BLOCK_PICTURE", @"PICTURE",
                            @"VIBE_CUSTOM", @"A=B"]) {
        [self assertFailure:url code:VibeTagWriteErrorInvalidField fields:@{key: @[@"x"]}];
    }
    [self assertWrite:url fields:@{@"title": @[@"Lower case names the field"]}];
    XCTAssertEqualObjects([self read:url][VibeTagFieldTitle], @[@"Lower case names the field"]);
}

@end
