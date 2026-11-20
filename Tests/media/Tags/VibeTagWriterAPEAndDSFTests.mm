//
//  VibeTagWriterAPEAndDSFTests.mm
//  vibe-libs
//
//  What VibeTagWriterTests' shared cases cannot say of the formats with an
//  APEv2 tag, WavPack and Monkey's Audio, and of DSF, whose ID3v2 tag sits
//  at the file's end behind a pointer in its header. A hybrid WavPack
//  file's correction file is never touched. An APE tag holds one front and
//  one back cover. A tag that grows and then goes leaves the file's bytes
//  as they were. A DSF whose pointer would put the tag in its audio is
//  refused, and so are audio walks that do not add up.
//

#import <XCTest/XCTest.h>

#import "AudioFileFixtures.h"
#import "AudioTrackMetadataTagFixtures.h"
#import "DSFFixtures.h"
#import "TagLibAudioFile.h"
#import "VibeTagWriter.h"

#include <signal.h>
#include <sys/resource.h>
#include <apefile.h>
#include <apetag.h>
#include <id3v1tag.h>
#include <wavpackfile.h>

@interface VibeTagWriterAPEAndDSFTests : XCTestCase
@end

static NSData *VibeCover(CGFloat shade) { return VibeImageOfColor(8, shade, 0.2, 0.3, UTTypeJPEG); }

static NSData *VibeDigestOf(NSURL *url) {
    NSError *error = nil;
    NSData *digest = VibeTagLibAudioDigest(url.path, &error);
    if (!digest) NSLog(@"%@: %@", url.lastPathComponent, error);
    return digest;
}

static VibeTagPicture *VibePicture(NSData *data, VibeTagPictureType type, NSString *description) {
    return [[VibeTagPicture alloc] initWithData:data mimeType:nil type:type description:description];
}

@implementation VibeTagWriterAPEAndDSFTests {
    NSURL *_dir;
}

- (void)setUp {
    [super setUp];
    _dir = VibeTagFixtureDirectory();
}

- (void)tearDown {
    [NSFileManager.defaultManager removeItemAtURL:_dir error:NULL];
    [super tearDown];
}

// A copy of a fixture in the test's folder.
- (NSURL *)copy:(NSURL *)fixture as:(NSString *)name {
    NSURL *url = [_dir URLByAppendingPathComponent:name];
    [NSFileManager.defaultManager removeItemAtURL:url error:NULL];
    NSError *error = nil;
    XCTAssertTrue([NSFileManager.defaultManager copyItemAtURL:fixture toURL:url error:&error], @"%@", error);
    return url;
}

- (NSURL *)dsf:(NSString *)name tag:(NSData *)tag {
    NSURL *url = [_dir URLByAppendingPathComponent:name];
    XCTAssertTrue([VibeDSFFile(2, 1, YES, 44100, VibeDSFSine(1000, 0.5), tag) writeToURL:url atomically:YES]);
    return url;
}

// A file of each format with no tag at all.
- (NSArray<NSURL *> *)untagged {
    return @[[self copy:[NSURL fileURLWithPath:[@__FILE__.stringByDeletingLastPathComponent
                                                   stringByAppendingPathComponent:@"../../Fuzz/Seeds/tags-wv/plain.wv"]]
                     as:@"plain.wv"],
             [self copy:VibeAPEFixture(@"level-normal.ape") as:@"plain.ape"], [self dsf:@"plain.dsf" tag:nil]];
}

- (void)assertWrite:(NSURL *)url fields:(VibeTagFieldValues *)fields {
    NSError *error = nil;
    XCTAssertTrue(VibeTagLibWriteTags(url.path, fields, NO, nil, nil, VibeTagWriteSyncFull, NULL, &error), @"%@: %@",
                  url.lastPathComponent, error);
}

- (void)assertRefusal:(NSURL *)url code:(VibeTagWriteError)code {
    NSData *before = [NSData dataWithContentsOfURL:url];
    NSError *error = nil;
    XCTAssertFalse(VibeTagLibWriteTags(url.path, @{VibeTagFieldTitle: @[@"Title"]}, YES, VibeCover(0.4), @"image/jpeg",
                                       VibeTagWriteSyncFull, NULL, &error), @"%@", url.lastPathComponent);
    XCTAssertEqual(error.code, code, @"%@: %@", url.lastPathComponent, error);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:url], before, @"%@", url.lastPathComponent);
}

#pragma mark - Every format

// A file with no tag gets one, every field and a cover in it. A tag that
// grows past what it was, and then shrinks, reads back each time. Removed
// whole, it leaves the file's bytes as they were before the first write,
// and the DSF's header with its size and no pointer.
- (void)testATagThatGrowsAndShrinksLeavesTheFileAsItWas {
    NSString *longTitle = [@"" stringByPaddingToLength:20000 withString:@"t" startingAtIndex:0];
    for (NSURL *url in self.untagged) {
        NSString *name = url.lastPathComponent;
        NSData *original = [NSData dataWithContentsOfURL:url];
        NSData *audio = VibeDigestOf(url);
        XCTAssertNotNil(audio, @"%@", name);
        NSError *error = nil;
        XCTAssertTrue(VibeTagLibWriteTags(url.path, @{VibeTagFieldTitle: @[@"Short"], VibeTagFieldArtist: @[@"Artist"]},
                                          YES, VibeCover(0.5), @"image/jpeg", VibeTagWriteSyncFull, NULL, &error),
                      @"%@: %@", name, error);
        [self assertWrite:url fields:@{VibeTagFieldTitle: @[longTitle]}];
        XCTAssertEqualObjects(VibeTagLibReadFields(url.path, NULL)[VibeTagFieldTitle], @[longTitle], @"%@", name);
        [self assertWrite:url fields:@{VibeTagFieldTitle: @[@"S"]}];
        VibeTagFieldValues *read = VibeTagLibReadFields(url.path, NULL);
        XCTAssertEqualObjects(read[VibeTagFieldTitle], @[@"S"], @"%@", name);
        XCTAssertEqualObjects(read[VibeTagFieldArtist], @[@"Artist"], @"%@", name);
        NSData *art = nil;
        XCTAssertTrue(VibeTagLibReadEmbeddedArt(url.path, nil, 0, &art));
        XCTAssertEqualObjects(art, VibeCover(0.5), @"%@", name);
        XCTAssertEqualObjects(VibeDigestOf(url), audio, @"%@", name);
        XCTAssertTrue(VibeTagLibWriteTags(url.path, @{VibeTagFieldTitle: @[], VibeTagFieldArtist: @[]}, YES, nil, nil,
                                          VibeTagWriteSyncFull, NULL, &error), @"%@: %@", name, error);
        XCTAssertEqualObjects([NSData dataWithContentsOfURL:url], original, @"%@ is as it was", name);
    }
}

// A write past the file size limit fails with SaveFailed in each format,
// where TagLib's own stream answers success. The file may be part written,
// so an app writes a copy (media/Tags/AGENTS.md, Writing).
- (void)testAFailedWriteFails {
    NSMutableData *cover = [VibeCover(0.6) mutableCopy];
    [cover increaseLengthBy:200000];
    for (NSURL *url in self.untagged) {
        NSData *before = [NSData dataWithContentsOfURL:url];
        struct rlimit saved;
        getrlimit(RLIMIT_FSIZE, &saved);
        void (*handler)(int) = signal(SIGXFSZ, SIG_IGN);
        struct rlimit limit = saved;
        limit.rlim_cur = before.length + 1000;
        setrlimit(RLIMIT_FSIZE, &limit);
        NSError *error = nil;
        const BOOL wrote = VibeTagLibWriteTags(url.path, nil, YES, cover, @"image/jpeg", VibeTagWriteSyncFull, NULL,
                                               &error);
        setrlimit(RLIMIT_FSIZE, &saved);
        signal(SIGXFSZ, handler);
        XCTAssertFalse(wrote, @"%@", url.lastPathComponent);
        XCTAssertEqual(error.code, VibeTagWriteErrorSaveFailed, @"%@: %@", url.lastPathComponent, error);
    }
}

#pragma mark - WavPack

// TagLib opens the .wv alone. A hybrid file's correction file keeps every
// byte through a write of the fields, a cover, and their removal.
- (void)testAHybridWriteLeavesItsCorrectionFile {
    NSURL *wv = [self copy:VibeWavPackFixture(@"hybrid.wv") as:@"hybrid.wv"];
    NSURL *wvc = [self copy:VibeWavPackFixture(@"hybrid.wvc") as:@"hybrid.wvc"];
    NSData *correction = [NSData dataWithContentsOfURL:wvc];
    NSDictionary<NSFileAttributeKey, id> *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:wvc.path
                                                                                                    error:NULL];
    NSData *audio = VibeDigestOf(wv);
    NSError *error = nil;
    XCTAssertTrue(VibeTagLibWriteTags(wv.path, @{VibeTagFieldTitle: @[@"Hybrid"]}, YES, VibeCover(0.3), @"image/jpeg",
                                      VibeTagWriteSyncFull, NULL, &error), @"%@", error);
    XCTAssertTrue(VibeTagLibWriteTags(wv.path, @{VibeTagFieldTitle: @[]}, YES, nil, nil, VibeTagWriteSyncFull, NULL,
                                      &error), @"%@", error);
    XCTAssertEqualObjects(VibeDigestOf(wv), audio);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:wvc], correction);
    XCTAssertEqualObjects([NSFileManager.defaultManager attributesOfItemAtPath:wvc.path error:NULL]
                                  [NSFileModificationDate], attributes[NSFileModificationDate]);
}

// TRAP: TagLib reads the first tag that is not empty. A WavPack file with
// an ID3v1 tag alone gains an APE tag holding the ID3v1 tag's fields and the
// edit, so no field the file read is hidden. The ID3v1 tag takes the edit.
- (void)testAnID3v1TagAloneKeepsItsFields {
    NSURL *url = [self copy:[NSURL fileURLWithPath:[@__FILE__.stringByDeletingLastPathComponent
                                                       stringByAppendingPathComponent:@"../../Fuzz/Seeds/tags-wv/plain.wv"]]
                         as:@"id3v1.wv"];
    {
        TagLib::WavPack::File file(url.fileSystemRepresentation);
        file.strip(TagLib::WavPack::File::APE);
        file.ID3v1Tag(true)->setArtist("Old Artist");
        file.ID3v1Tag(true)->setAlbum("Old Album");
        XCTAssertTrue(file.save());
        XCTAssertFalse(file.hasAPETag());
    }
    [self assertWrite:url fields:@{VibeTagFieldTitle: @[@"New Title"]}];
    VibeTagFieldValues *read = VibeTagLibReadFields(url.path, NULL);
    XCTAssertEqualObjects(read[VibeTagFieldTitle], @[@"New Title"]);
    XCTAssertEqualObjects(read[VibeTagFieldArtist], @[@"Old Artist"]);
    XCTAssertEqualObjects(read[VibeTagFieldAlbum], @[@"Old Album"]);
    TagLib::WavPack::File file(url.fileSystemRepresentation);
    XCTAssertTrue(file.hasAPETag());
    XCTAssertEqual(file.ID3v1Tag()->title(), TagLib::String("New Title"));
}

#pragma mark - APE ratings

// foobar2000 writes RATING into a WavPack file's APE tag. The rating read
// answers it, and a write of RATING replaces it. An ID3v1 tag beside the
// APE tag never takes a rating.
- (void)testAnAPERatingReadsAndWrites {
    NSURL *url = [self copy:[NSURL fileURLWithPath:[@__FILE__.stringByDeletingLastPathComponent
                                                       stringByAppendingPathComponent:@"../../Fuzz/Seeds/tags-wv/plain.wv"]]
                         as:@"rated.wv"];
    {
        TagLib::WavPack::File file(url.fileSystemRepresentation);
        file.APETag(true)->addValue("Rating", "4");
        file.ID3v1Tag(true)->setTitle("Title");
        XCTAssertTrue(file.save());
    }
    {
        TagLibAudioFile file(url.fileSystemRepresentation, false);
        XCTAssertEqualObjects(VibeTagRatingFields(file.file(), file.file()->properties()), (@{VibeTagFieldRating: @"4"}));
    }
    [self assertWrite:url fields:@{VibeTagFieldRating: @[@"80"], VibeTagFieldFMPSRating: @[@"0.8"]}];
    VibeTagFieldValues *read = VibeTagLibReadFields(url.path, NULL);
    XCTAssertEqualObjects(read[VibeTagFieldRating], @[@"80"]);
    XCTAssertEqualObjects(read[VibeTagFieldFMPSRating], @[@"0.8"]);
    TagLib::WavPack::File file(url.fileSystemRepresentation);
    XCTAssertEqual(file.APETag()->itemListMap()["RATING"].toString(), TagLib::String("80"), @"one RATING item");
    XCTAssertEqual(file.ID3v1Tag()->title(), TagLib::String("Title"));
}

#pragma mark - APE pictures

// An APE tag holds a front and a back cover, each with its description,
// and gives them back in that order whatever order they came in. A cover
// write replaces the front cover and keeps the back. Any other type, or two
// of one, is refused before the file changes, and PicturesFit says so.
- (void)testAnAPETagHoldsAFrontAndABackCover {
    for (NSString *name in @[@"covers.wv", @"covers.ape"]) {
        NSURL *url = [name hasSuffix:@"wv"] ? [self copy:VibeWavPackFixture(@"s16.wv") as:name]
                                            : [self copy:VibeAPEFixture(@"level-normal.ape") as:name];
        NSData *audio = VibeDigestOf(url);
        VibeTagPicture *front = VibePicture(VibeCover(0.1), VibeTagPictureTypeFrontCover, @"front.jpg");
        VibeTagPicture *back = VibePicture(VibeCover(0.9), VibeTagPictureTypeBackCover, @"");
        NSError *error = nil;
        XCTAssertTrue(VibeTagLibWritePictures(url.path, @[back, front], VibeTagWriteSyncFull, NULL, &error), @"%@: %@",
                      name, error);
        NSArray<VibeTagPicture *> *pictures = nil;
        NSUInteger shown = NSNotFound;
        XCTAssertTrue(VibeTagLibReadPictures(url.path, &pictures, &shown, &error));
        XCTAssertEqualObjects(pictures, (@[front, back]), @"%@", name);
        XCTAssertEqual(shown, 0u, @"%@", name);
        XCTAssertEqualObjects(pictures[0].imageMIMEType, @"image/jpeg", @"%@ sniffs the type", name);

        XCTAssertTrue(VibeTagLibWriteTags(url.path, nil, YES, VibeCover(0.5), @"image/jpeg", VibeTagWriteSyncFull, NULL,
                                          &error), @"%@: %@", name, error);
        XCTAssertTrue(VibeTagLibReadPictures(url.path, &pictures, &shown, &error));
        XCTAssertEqualObjects(pictures, (@[VibePicture(VibeCover(0.5), VibeTagPictureTypeFrontCover, @""), back]),
                              @"%@", name);
        // The removal takes the front cover, then the back cover shows.
        XCTAssertTrue(VibeTagLibWriteTags(url.path, nil, YES, nil, nil, VibeTagWriteSyncFull, NULL, &error));
        NSData *art = nil;
        XCTAssertTrue(VibeTagLibReadEmbeddedArt(url.path, nil, 0, &art));
        XCTAssertEqualObjects(art, back.data, @"%@", name);

        for (NSArray<VibeTagPicture *> *list in @[@[VibePicture(VibeCover(0.2), VibeTagPictureTypeOther, @"")],
                                                  @[VibePicture(VibeCover(0.2), VibeTagPictureTypeUntyped, @"")],
                                                  @[VibePicture(VibeCover(0.2), (VibeTagPictureType)8, @"")],
                                                  @[front, front], @[back, back]]) {
            NSData *before = [NSData dataWithContentsOfURL:url];
            NSError *fitError = nil;
            XCTAssertFalse(VibeTagLibPicturesFit(list, VibeTagContainerAPE, &fitError), @"%@ %@", name, list);
            XCTAssertEqual(fitError.code, VibeTagWriteErrorInvalidImage);
            XCTAssertFalse(VibeTagLibWritePictures(url.path, list, VibeTagWriteSyncFull, NULL, &error), @"%@", name);
            XCTAssertEqual(error.code, VibeTagWriteErrorInvalidImage, @"%@: %@", name, error);
            XCTAssertEqualObjects([NSData dataWithContentsOfURL:url], before, @"%@", name);
        }
        XCTAssertTrue(VibeTagLibPicturesFit(@[front, back], VibeTagContainerAPE, NULL));
        XCTAssertEqualObjects(VibeDigestOf(url), audio, @"%@", name);
    }
}

#pragma mark - DSF

// The DSF's header after a write: its size names the file's length, and its
// pointer the ID3v2 tag at its end.
- (void)testADSFHeaderNamesItsSizeAndTag {
    NSURL *url = [self dsf:@"header.dsf" tag:nil];
    [self assertWrite:url fields:@{VibeTagFieldTitle: @[@"Title"]}];
    NSData *bytes = [NSData dataWithContentsOfURL:url];
    const uint8_t *b = (const uint8_t *)bytes.bytes;
    uint64_t size = 0, pointer = 0;
    memcpy(&size, b + 12, 8);
    memcpy(&pointer, b + 20, 8);
    XCTAssertEqual(size, bytes.length);
    XCTAssertGreaterThan(pointer, 0u);
    XCTAssertEqual(memcmp(b + pointer, "ID3\x04", 4), 0, @"a new tag is ID3v2.4");
}

// A pointer inside the audio, or to bytes that are no ID3v2 tag, and a data
// chunk that passes the file's stated size, are refused, and the file's
// bytes stay.
- (void)testADSFWhoseTagWouldLandInItsAudioRefuses {
    NSData *plain = VibeDSFFile(2, 1, YES, 44100, VibeDSFSine(1000, 0.5), nil);
    auto patched = [&](NSString *name, NSUInteger at, uint64_t value) {
        NSMutableData *bytes = [plain mutableCopy];
        [bytes replaceBytesInRange:NSMakeRange(at, 8) withBytes:&value];
        NSURL *url = [_dir URLByAppendingPathComponent:name];
        XCTAssertTrue([bytes writeToURL:url atomically:YES]);
        return url;
    };
    [self assertRefusal:patched(@"inside.dsf", 20, 200) code:VibeTagWriteErrorWouldLoseData];
    NSMutableData *junk = [plain mutableCopy];
    [junk appendBytes:"JUNKJUNKJUNK" length:12];
    uint64_t size = junk.length, pointer = plain.length;
    [junk replaceBytesInRange:NSMakeRange(12, 8) withBytes:&size];
    [junk replaceBytesInRange:NSMakeRange(20, 8) withBytes:&pointer];
    NSURL *notID3 = [_dir URLByAppendingPathComponent:@"junk.dsf"];
    XCTAssertTrue([junk writeToURL:notID3 atomically:YES]);
    [self assertRefusal:notID3 code:VibeTagWriteErrorWouldLoseData];
    // The data chunk's size reaches past the file's stated size.
    [self assertRefusal:patched(@"long.dsf", 84, plain.length) code:VibeTagWriteErrorWouldLoseData];
}

#pragma mark - The walks

// A walk that does not add up finds no audio: a WavPack block that runs
// past the tags, a Monkey's Audio file whose stated frames pass its end,
// and a DSF data chunk that passes the file's.
- (void)testAWalkThatDoesNotAddUpFindsNoAudio {
    NSMutableData *wv = [[NSData dataWithContentsOfURL:VibeWavPackFixture(@"s16.wv")] mutableCopy];
    const uint32_t huge = 0x7FFFFFF0;
    [wv replaceBytesInRange:NSMakeRange(4, 4) withBytes:&huge];
    NSMutableData *ape = [[NSData dataWithContentsOfURL:VibeAPEFixture(@"level-normal.ape")] mutableCopy];
    [ape replaceBytesInRange:NSMakeRange(24, 4) withBytes:&huge];
    NSMutableData *dsf = [VibeDSFFile(2, 1, YES, 44100, VibeDSFSine(1000, 0.5), nil) mutableCopy];
    const uint64_t longData = dsf.length;
    [dsf replaceBytesInRange:NSMakeRange(84, 8) withBytes:&longData];
    for (NSArray *pair in @[@[@"long.wv", wv], @[@"long.ape", ape], @[@"long.dsf", dsf]]) {
        NSURL *url = [_dir URLByAppendingPathComponent:pair[0]];
        XCTAssertTrue([pair[1] writeToURL:url atomically:YES]);
        NSError *error = nil;
        XCTAssertNil(VibeTagLibAudioDigest(url.path, &error), @"%@", pair[0]);
        XCTAssertEqual(error.code, VibeTagWriteErrorNoParser, @"%@: %@", pair[0], error);
    }
}

// Each walk covers what a write must keep: a byte of a WavPack block's
// header, of a Monkey's Audio file's header, and of a DSF's fmt chunk
// changes the digest. A DSF's stated size and tag pointer do not.
- (void)testEachWalkCoversItsHeaders {
    NSURL *wv = [self copy:VibeWavPackFixture(@"s16.wv") as:@"walk.wv"];
    NSURL *ape = [self copy:VibeAPEFixture(@"level-normal.ape") as:@"walk.ape"];
    NSURL *dsf = [self dsf:@"walk.dsf" tag:nil];
    for (NSArray *probe in @[@[wv, @9, @YES], @[ape, @40, @YES], @[dsf, @44, @YES], @[dsf, @12, @NO],
                             @[dsf, @20, @NO]]) {
        NSURL *url = probe[0];
        NSData *original = [NSData dataWithContentsOfURL:url];
        NSData *digest = VibeDigestOf(url);
        NSMutableData *bytes = [original mutableCopy];
        ((uint8_t *)bytes.mutableBytes)[[probe[1] unsignedIntegerValue]] ^= 0x01;
        XCTAssertTrue([bytes writeToURL:url atomically:YES]);
        NSData *after = VibeTagLibAudioDigest(url.path, NULL);
        if ([probe[2] boolValue]) XCTAssertNotEqualObjects(after, digest, @"%@ byte %@", url.lastPathComponent, probe[1]);
        else XCTAssertEqualObjects(after, digest, @"%@ byte %@", url.lastPathComponent, probe[1]);
        XCTAssertTrue([original writeToURL:url atomically:YES]);
    }
}

@end
