//
//  AudioTrackMetadataTagTests.mm
//  The metadata tests
//
//  The real tag parse over the real TagLib: each format's tags and facts, the
//  tagged tempo and key, each tag field alone and all of them at once, FLAC's
//  audio MD5, embedded art through the bounded decode, and the parse of a file
//  whose extension misleads. vibe-libs' media/Tags tests the
//  detection itself. Every file is written here
//  (AudioTrackMetadataTagFixtures.h), except Ogg's audio, which comes from the
//  generated fixtures VIBE_AUDIO_FIXTURES names. Those tests skip without them.
//

#import <XCTest/XCTest.h>

#import "ArchivedArtShare.h"
#import "AudioFileHandle.h"
#import "AudioTrackMetadataInternal.h"
#import "AudioTrackMetadataTagFixtures.h"
#import "PlatformImage.h"
#import "CloudFileMaterializer.h"

#import <CommonCrypto/CommonDigest.h>

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

@interface AudioTrackMetadataTagTests : XCTestCase
@end

// Each fixture tagged with the class's art, written once for the class.
// A test gets a copy in its own directory, so it may change the copy.
static NSURL *sFixtureDir;
static NSDictionary<NSNumber *, NSURL *> *sFixtures;
static NSData *sArt;

// An entry archived before kindByCodec, as an older store holds one. Only
// its kind is archived.
@interface OldKindEntry : NSObject <NSCoding>
@property (copy) NSString *fileType;
@end

@implementation OldKindEntry
- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.fileType forKey:@"fileType"];
}
- (instancetype)initWithCoder:(NSCoder *)coder {
    return [super init];
}
@end

@implementation AudioTrackMetadataTagTests {
    NSURL *_dir;
}

+ (void)setUp {
    [super setUp];
    sArt = VibeImageOfColor(300, 0.8, 0.2, 0.3, UTTypePNG);
    sFixtureDir = VibeTagFixtureDirectory();
    NSMutableDictionary<NSNumber *, NSURL *> *fixtures = [NSMutableDictionary dictionary];
    for (NSInteger fixture = 0; fixture < VibeTagFixtureCount; fixture++) {
        fixtures[@(fixture)] = VibeWriteTagFixture(sFixtureDir, (VibeTagFixture)fixture, sArt, NULL);
    }
    sFixtures = fixtures;
}

+ (void)tearDown {
    [NSFileManager.defaultManager removeItemAtURL:sFixtureDir error:NULL];
    [super tearDown];
}

- (void)setUp {
    [super setUp];
    _dir = VibeTagFixtureDirectory();
    // The share is the process's, and most fixtures embed one picture.
    VibeArchivedArtShareResetForTesting();
}

- (void)tearDown {
    [NSFileManager.defaultManager removeItemAtURL:_dir error:NULL];
    [super tearDown];
}

// The class's copy when `art` is the class's or the format carries none.
// Other art is written fresh.
- (NSURL *)write:(VibeTagFixture)fixture art:(NSData *)art {
    NSURL *url = nil;
    if (art == sArt || !VibeTagFixtureHasArt(fixture)) {
        NSURL *written = sFixtures[@(fixture)];
        NSURL *copy = [_dir URLByAppendingPathComponent:VibeTagFixtureName(fixture)];
        [NSFileManager.defaultManager removeItemAtURL:copy error:NULL];
        if (written && [NSFileManager.defaultManager copyItemAtURL:written toURL:copy error:NULL]) url = copy;
    }
    else {
        url = VibeWriteTagFixture(_dir, fixture, art, NULL);
    }
    if (fixture == VibeTagFixtureVorbis || fixture == VibeTagFixtureOpus) {
        XCTSkipUnless(url != nil, @"%@ needs the render fixtures; run make test-audio with ffmpeg installed",
                      VibeTagFixtureName(fixture));
    }
    XCTAssertNotNil(url, @"%@", VibeTagFixtureName(fixture));
    return url;
}

// The parse the loader runs on a cache miss, with the folder's cover kept
// out so only the file's own art can answer.
static AudioTrackMetadata *Parse(NSURL *url, NSData *__autoreleasing *displayArt) {
    AudioTrackMetadata *metadata = [AudioTrackMetadata metadataWithURL:url displayArtData:displayArt];
    metadata.artwork.folderArt = nil;
    return metadata;
}

static VibeEmbeddedArtExtractionResult Extract(NSURL *url, NSData *__autoreleasing *art) {
    return VibeTagLibArtExtractor()(url.path, art);
}

// The metadata cache's own round trip: PINDiskCache's default archive, and
// its unarchive without secure coding.
static AudioTrackMetadata *CacheRoundTrip(AudioTrackMetadata *metadata) {
    NSData *archive = [NSKeyedArchiver archivedDataWithRootObject:metadata requiringSecureCoding:NO error:NULL];
    NSKeyedUnarchiver *unarchiver = [[NSKeyedUnarchiver alloc] initForReadingFromData:archive error:NULL];
    unarchiver.requiresSecureCoding = NO;
    return [unarchiver decodeObjectForKey:NSKeyedArchiveRootObjectKey];
}

// The MD5 FLAC's STREAMINFO holds for the fixtures' tone: its samples
// interleaved, little-endian, two bytes each.
static NSData *ToneMD5(void) {
    AVAudioPCMBuffer *tone = VibeToneBuffer(22050, 44100, 2, AVAudioPCMFormatInt16);
    uint8_t digest[CC_MD5_DIGEST_LENGTH];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CC_MD5(tone.int16ChannelData[0], (CC_LONG)(tone.frameLength * 2 * sizeof(int16_t)), digest);
#pragma clang diagnostic pop
    return [NSData dataWithBytes:digest length:sizeof digest];
}

// Every field in `tagged` reads as the fixtures write it. Every other field
// reads as untagged: nil, 0, or NO.
- (void)assertFields:(NSIndexSet *)tagged of:(AudioTrackMetadata *)metadata fixture:(VibeTagFixture)fixture
               label:(NSString *)label {
    BOOL counts = VibeTagFixtureHasCounts(fixture);
    for (NSInteger index = 0; index < VibeTagFixtureFieldCount; index++) {
        VibeTagFixtureField field = (VibeTagFixtureField)index;
        BOOL on = [tagged containsIndex:(NSUInteger)field];
        NSString *name = [NSString stringWithFormat:@"%@: %@", label, VibeTagFixtureFieldName(field)];
        void (^text)(NSString *, NSString *) = ^(NSString *value, NSString *expected) {
            XCTAssertEqualObjects(value, on ? expected : nil, @"%@", name);
        };
        void (^number)(NSNumber *, double) = ^(NSNumber *value, double expected) {
            if (on) {
                XCTAssertNotNil(value, @"%@", name);
                XCTAssertEqualWithAccuracy(value.doubleValue, expected, 1e-9, @"%@", name);
            }
            else {
                XCTAssertNil(value, @"%@", name);
            }
        };
        if (VibeTagFixtureFieldIsExtra(field)) {
            text([metadata extraTag:@(VibeTagExtraName(field))], VibeTagExtraValue(field, fixture));
            if (field == VibeTagFixtureFieldOriginalDate) {
                XCTAssertEqual(metadata.originalYear, on ? kVibeTagOriginalYear : 0, @"%@", name);
            }
            continue;
        }
        switch (field) {
            case VibeTagFixtureFieldAlbum: text(metadata.album, kVibeTagAlbum); break;
            case VibeTagFixtureFieldAlbumArtist: text(metadata.albumArtist, kVibeTagAlbumArtist); break;
            case VibeTagFixtureFieldGenre: text(metadata.genre, kVibeTagGenre); break;
            case VibeTagFixtureFieldComposer: text(metadata.composer, kVibeTagComposer); break;
            case VibeTagFixtureFieldYear: XCTAssertEqual(metadata.year, on ? kVibeTagYear : 0, @"%@", name); break;
            case VibeTagFixtureFieldTrack:
                XCTAssertEqual(metadata.trackNumber, on ? 3 : 0, @"%@", name);
                XCTAssertEqual(metadata.trackCount, on && counts ? 12 : 0, @"%@", name);
                break;
            case VibeTagFixtureFieldDisc:
                XCTAssertEqual(metadata.discNumber, on ? 1 : 0, @"%@", name);
                XCTAssertEqual(metadata.discCount, on ? 2 : 0, @"%@", name);
                break;
            case VibeTagFixtureFieldCompilation: XCTAssertEqual(metadata.isCompilation, on, @"%@", name); break;
            case VibeTagFixtureFieldReleaseID: text(metadata.musicBrainzReleaseID, kVibeTagReleaseID); break;
            case VibeTagFixtureFieldRecordingID: text(metadata.musicBrainzRecordingID, kVibeTagRecordingID); break;
            case VibeTagFixtureFieldISRC: text(metadata.isrc, kVibeTagISRC); break;
            case VibeTagFixtureFieldReplayGainTrackGain: number(metadata.replayGainTrackGain, -6.54); break;
            case VibeTagFixtureFieldReplayGainTrackPeak: number(metadata.replayGainTrackPeak, 0.988547); break;
            case VibeTagFixtureFieldReplayGainAlbumGain: number(metadata.replayGainAlbumGain, 1.25); break;
            case VibeTagFixtureFieldReplayGainAlbumPeak: number(metadata.replayGainAlbumPeak, 1); break;
            case VibeTagFixtureFieldR128TrackGain: number(metadata.r128TrackGain, -1234 / 256.0); break;
            case VibeTagFixtureFieldR128AlbumGain: number(metadata.r128AlbumGain, -2); break;
            case VibeTagFixtureFieldSoundCheck: number(metadata.soundCheckGain, kVibeTagSoundCheckGain); break;
            case VibeTagFixtureFieldComment: text(metadata.comment, kVibeTagComment); break;
            case VibeTagFixtureFieldGrouping: text(metadata.grouping, kVibeTagGrouping); break;
            case VibeTagFixtureFieldLabel: text(metadata.label, kVibeTagLabel); break;
            case VibeTagFixtureFieldCount: break;
            case VibeTagFixtureFieldCatalogNumber: case VibeTagFixtureFieldConductor: case VibeTagFixtureFieldRemixer:
            case VibeTagFixtureFieldLyricist: case VibeTagFixtureFieldMood: case VibeTagFixtureFieldLanguage: case VibeTagFixtureFieldCopyright:
            case VibeTagFixtureFieldOriginalDate: case VibeTagFixtureFieldTitleSort: case VibeTagFixtureFieldArtistSort:
            case VibeTagFixtureFieldAlbumSort: case VibeTagFixtureFieldAlbumArtistSort: break; // above
        }
    }
}

// The fields `fixture` carries.
static NSIndexSet *CarriedFields(VibeTagFixture fixture) {
    NSMutableIndexSet *fields = [NSMutableIndexSet indexSet];
    for (NSInteger field = 0; field < VibeTagFixtureFieldCount; field++) {
        if (VibeTagFixtureCarries(fixture, (VibeTagFixtureField)field)) [fields addIndex:(NSUInteger)field];
    }
    return fields;
}

static BOOL IsFLAC(VibeTagFixture fixture) {
    return fixture == VibeTagFixtureFLAC || fixture == VibeTagFixtureFLACCueSheet;
}

// Every lossless fixture is 16-bit. A lossy codec has no depth.
static NSInteger FixtureBitDepth(VibeTagFixture fixture) {
    switch (fixture) {
        case VibeTagFixtureFLAC: case VibeTagFixtureFLACCueSheet: case VibeTagFixtureWAVID3:
        case VibeTagFixtureWAVInfo: case VibeTagFixtureAIFF: case VibeTagFixtureCAF: case VibeTagFixtureW64:
            return 16;
        default:
            return 0;
    }
}

- (void)assertFixture:(VibeTagFixture)fixture fileType:(VibeAudioFileFormat)fileType rate:(int)rate
             duration:(NSTimeInterval)duration {
    NSURL *url = [self write:fixture art:sArt];
    NSString *name = VibeTagFixtureName(fixture);
    NSData *displayArt = nil;
    AudioTrackMetadata *metadata = Parse(url, &displayArt);
    XCTAssertTrue(metadata.parsedOK, @"%@", name);
    XCTAssertEqualObjects(metadata.fileType, fileType, @"%@", name);
    XCTAssertEqualObjects(metadata.sampleRate, @(rate), @"%@", name);
    XCTAssertEqualWithAccuracy(metadata.duration, duration, 0.06, @"%@", name);
    if (fixture == VibeTagFixtureW64) {
        XCTAssertEqualObjects(metadata.title, @"plain", @"%@: the filename stands in", name);
        XCTAssertNil(metadata.artist, @"%@", name);
    }
    else {
        XCTAssertEqualObjects(metadata.title, kVibeTagTitle, @"%@", name);
        XCTAssertEqualObjects(metadata.artist, kVibeTagArtist, @"%@", name);
    }

    if (VibeTagFixtureHasBPMAndKey(fixture)) {
        // MP4's tmpo atom holds a whole number.
        XCTAssertEqual(metadata.bpm, fixture == VibeTagFixtureM4A ? floorf(kVibeTagBPM) : kVibeTagBPM, @"%@", name);
        XCTAssertEqual(metadata.key, VibeMusicalKeyMake(9, YES), @"%@", name);
    }
    else {
        XCTAssertEqual(metadata.bpm, 0.0f, @"%@", name);
        XCTAssertEqual(metadata.key, VibeMusicalKeyNone, @"%@: untagged is None, never C major", name);
    }

    // Every field the format carries, at once, and through the cache's
    // archive and a copy.
    NSIndexSet *fields = CarriedFields(fixture);
    [self assertFields:fields of:metadata fixture:fixture label:name];
    AudioTrackMetadata *restored = CacheRoundTrip(metadata);
    XCTAssertNotNil(restored, @"%@", name);
    [self assertFields:fields of:restored fixture:fixture label:[name stringByAppendingString:@" archived"]];
    [self assertFields:fields of:[metadata copy] fixture:fixture label:[name stringByAppendingString:@" copied"]];
    NSData *md5 = IsFLAC(fixture) ? ToneMD5() : nil;
    XCTAssertEqualObjects(metadata.audioMD5, md5, @"%@", name);
    XCTAssertEqualObjects(restored.audioMD5, md5, @"%@ archived", name);
    XCTAssertEqualObjects(((AudioTrackMetadata *)[metadata copy]).audioMD5, md5, @"%@ copied", name);
    XCTAssertEqual(metadata.bitDepth, FixtureBitDepth(fixture), @"%@", name);
    XCTAssertEqual(restored.bitDepth, FixtureBitDepth(fixture), @"%@ archived", name);
    XCTAssertEqual(((AudioTrackMetadata *)[metadata copy]).bitDepth, FixtureBitDepth(fixture), @"%@ copied", name);

    NSData *extracted = nil;
    VibeEmbeddedArtExtractionResult result = Extract(url, &extracted);
    // The art lives in the art's stores, never in the archived entry.
    XCTAssertNil(restored.artwork.encodedThumbnailDataForStorage, @"%@ archived", name);
    XCTAssertEqual(restored.hasEmbeddedArt, VibeTagFixtureHasArt(fixture), @"%@ archived", name);
    XCTAssertEqual(metadata.hasEmbeddedArt, VibeTagFixtureHasArt(fixture), @"%@", name);
    if (VibeTagFixtureHasArt(fixture)) {
        XCTAssertTrue(metadata.artwork.hasEmbeddedArt, @"%@", name);
        NSData *thumbnail = metadata.artwork.encodedThumbnailDataForStorage;
        XCTAssertNotNil(thumbnail, @"%@", name);
        CGSize size = VibeEncodedImagePixelSize(thumbnail);
        XCTAssertEqual(MAX(size.width, size.height), kVibeThumbnailArtDimension, @"%@", name);
        XCTAssertEqualObjects(displayArt, sArt, @"%@: art within the bound is archived verbatim", name);
        XCTAssertEqual(result, VibeEmbeddedArtExtractionFoundArt, @"%@", name);
        XCTAssertEqualObjects(extracted, sArt, @"%@", name);
        XCTAssertNotNil([metadata.artwork loadArtBlocking], @"%@", name);
    }
    else {
        XCTAssertFalse(metadata.artwork.hasEmbeddedArt, @"%@", name);
        XCTAssertNil(displayArt, @"%@", name);
        // TagLib has no CAF or W64 parser, so the art read cannot answer.
        BOOL coreAudio = fixture == VibeTagFixtureCAF || fixture == VibeTagFixtureW64;
        XCTAssertEqual(result, coreAudio ? VibeEmbeddedArtExtractionReadFailed : VibeEmbeddedArtExtractionNoArt,
                       @"%@", name);
    }
}

#pragma mark - Formats

// The 38 frames of 1152 at 44.1 kHz that the Info frame counts. The count leaves the Info frame out.
static const NSTimeInterval kMP3Duration = 38 * 1152 / 44100.0;

- (void)testMP3WithID3v23 {
    [self assertFixture:VibeTagFixtureMP3ID3v23 fileType:VibeAudioFileFormatMP3 rate:44100 duration:kMP3Duration];
}

- (void)testMP3WithID3v24 {
    [self assertFixture:VibeTagFixtureMP3ID3v24 fileType:VibeAudioFileFormatMP3 rate:44100 duration:kMP3Duration];
}

- (void)testMP3WithID3v1Only {
    [self assertFixture:VibeTagFixtureMP3ID3v1 fileType:VibeAudioFileFormatMP3 rate:44100 duration:kMP3Duration];
    // TagLib divides the Info frame's bytes by the counted frames' time. The
    // bytes include the Info frame, so this 38-frame stream reads as 328.
    XCTAssertEqualWithAccuracy(Parse([_dir URLByAppendingPathComponent:@"id3v1.mp3"], NULL).bitrate.doubleValue, 320, 10);
}

// TagLib 2 reads an MPEG file's APE tag only under TAGLIB_WITH_APE, which
// the vendored taglib_config.h defines (MP3Gain writes one).
- (void)testMP3WithAnAPETag {
    [self assertFixture:VibeTagFixtureMP3APE fileType:VibeAudioFileFormatMP3 rate:44100 duration:kMP3Duration];
}

// A Monkey's Audio file's APEv2 tag, through the scan's parse. Its kind,
// depth, and losslessness come from TagLib. The fixture is audio/Decode's,
// made by the SDK's encoder.
- (void)testMonkeysAudioWithAnAPETag {
    NSURL *url = [_dir URLByAppendingPathComponent:@"tagged.ape"];
    XCTAssertTrue([NSFileManager.defaultManager copyItemAtURL:[[NSBundle bundleForClass:self.class]
                                                                  URLForResource:@"tagged" withExtension:@"ape"]
                                                        toURL:url error:NULL]);
    AudioTrackMetadata *metadata = Parse(url, NULL);
    XCTAssertEqualObjects(metadata.fileType, VibeAudioFileFormatMonkeysAudio);
    XCTAssertTrue(metadata.lossless);
    XCTAssertEqual(metadata.bitDepth, 16);
    XCTAssertEqualObjects(metadata.sampleRate, @44100);
    XCTAssertEqualWithAccuracy(metadata.duration, 0.1, 0.001);
    XCTAssertEqualObjects(metadata.title, @"Seed Title");
    XCTAssertEqualObjects(metadata.artist, @"Seed Artist");
    XCTAssertEqualObjects(metadata.album, @"Seed Album");
    XCTAssertEqual(metadata.trackNumber, 3);
    XCTAssertEqual(metadata.year, 2026);
}

// An entry that named an MP4's kind by its container misses, so the file
// is parsed again. Every other older entry stays a hit.
- (void)testAnOldMP4KindIsACacheMiss {
    for (VibeAudioFileFormat kind in @[VibeAudioFileFormatMP4, VibeAudioFileFormatMP3]) {
        OldKindEntry *old = [[OldKindEntry alloc] init];
        old.fileType = kind;
        NSKeyedArchiver *archiver = [[NSKeyedArchiver alloc] initRequiringSecureCoding:NO];
        [archiver setClassName:NSStringFromClass(AudioTrackMetadata.class) forClass:OldKindEntry.class];
        [archiver encodeObject:old forKey:NSKeyedArchiveRootObjectKey];
        NSKeyedUnarchiver *unarchiver = [[NSKeyedUnarchiver alloc] initForReadingFromData:archiver.encodedData
                                                                                    error:NULL];
        unarchiver.requiresSecureCoding = NO;
        AudioTrackMetadata *decoded = [unarchiver decodeObjectForKey:NSKeyedArchiveRootObjectKey];
        if ([kind isEqualToString:VibeAudioFileFormatMP4]) {
            XCTAssertNil(decoded);
        } else {
            XCTAssertEqualObjects(decoded.fileType, kind);
        }
    }
}

// AAC in M4A names its codec. The key rides iTunes' freeform atom.
- (void)testM4A {
    [self assertFixture:VibeTagFixtureM4A fileType:VibeAudioFileFormatAAC rate:44100 duration:0.5];
    XCTAssertGreaterThan(Parse([_dir URLByAppendingPathComponent:@"tagged.m4a"], NULL).bitrate.intValue, 0);
}

- (void)testFLACWithAVorbisCommentAndAPicture {
    [self assertFixture:VibeTagFixtureFLAC fileType:VibeAudioFileFormatFLAC rate:44100 duration:0.5];
}

// A CUESHEET block beside the tags, which TagLib's save keeps.
- (void)testFLACWithAnEmbeddedCueSheet {
    [self assertFixture:VibeTagFixtureFLACCueSheet fileType:VibeAudioFileFormatFLAC rate:44100 duration:0.5];
}

- (void)testOggVorbis {
    [self assertFixture:VibeTagFixtureVorbis fileType:VibeAudioFileFormatVorbis rate:48000 duration:2];
}

- (void)testOpus {
    [self assertFixture:VibeTagFixtureOpus fileType:VibeAudioFileFormatOpus rate:48000 duration:2];
}

- (void)testWAVWithID3 {
    [self assertFixture:VibeTagFixtureWAVID3 fileType:VibeAudioFileFormatWAV rate:44100 duration:0.5];
}

- (void)testWAVWithRIFFInfo {
    [self assertFixture:VibeTagFixtureWAVInfo fileType:VibeAudioFileFormatWAV rate:44100 duration:0.5];
}

- (void)testAIFFWithID3 {
    [self assertFixture:VibeTagFixtureAIFF fileType:VibeAudioFileFormatAIFF rate:44100 duration:0.5];
}

// CoreAudio's facts: TagLib cannot read CAF, so the info chunk names it.
- (void)testCAF {
    [self assertFixture:VibeTagFixtureCAF fileType:VibeAudioFileFormatCAF rate:44100 duration:0.5];
}

// The fuzz's find, VIBE_FUZZ_SEED=34462054683540093: its flips forge the info
// chunk's size and set its entry count to 0xF90000EE, and CoreAudio's info
// parser never returned. The count alone does not hang it. The chunk is
// refused before CoreAudio reads it, and the format facts stay.
- (void)testCAFInfoChunkWithAnImpossibleCountIsSkipped {
    NSURL *url = [self write:VibeTagFixtureCAF art:nil];
    NSMutableData *data = [NSMutableData dataWithContentsOfURL:url];
    uint8_t *bytes = (uint8_t *)data.mutableBytes;
    XCTAssertGreaterThan(data.length, 112u);
    XCTAssertEqual(memcmp(bytes + 52, "info", 4), 0, @"the fixture's layout moved");
    static const struct { NSUInteger at; uint8_t mask; } kFlips[] = {
            {85, 0xF6}, {63, 0xD8}, {64, 0xF9}, {70, 0x50}, {67, 0xEC}, {84, 0xE4}, {111, 0xE8}, {78, 0xF7}};
    for (const auto &flip : kFlips) bytes[flip.at] ^= flip.mask;
    XCTAssertEqual(CFSwapInt32BigToHost(*(const uint32_t *)(bytes + 64)), 0xF90000EEu);
    XCTAssertTrue([data writeToURL:url atomically:NO]);

    __block AudioTrackMetadata *metadata = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        metadata = Parse(url, NULL);
        dispatch_semaphore_signal(done);
    });
    XCTAssertEqual(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW,
                                                               (int64_t)(VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC))),
                   0, @"the parse never returned");
    XCTAssertTrue(metadata.parsedOK);
    XCTAssertEqualObjects(metadata.fileType, VibeAudioFileFormatCAF);
    XCTAssertEqualObjects(metadata.sampleRate, @44100);
    // The forged size hides the chunks after the info chunk, so CoreAudio
    // estimates no duration. That is the mutation's doing, not the guard's.
    XCTAssertEqualObjects(metadata.title, @"tagged", @"the filename stands in");
    XCTAssertNil(metadata.artist);
}

// Tests/Fuzz's tags-m4a find, kept there: a 1.6 KB M4A that TagLib refuses,
// whose ©alb item claims 1.38 GB past the file's end. CoreAudio's info
// dictionary read sized its copy from the claim, and allocated and touched
// 4.3 GB. The item list is refused before CoreAudio reads it, and the format
// facts stay.
- (void)testMP4ItemPastTheFileIsSkipped {
    NSString *here = [@__FILE__ stringByDeletingLastPathComponent];
    NSURL *url = [NSURL fileURLWithPath:[here stringByAppendingPathComponent:
            @"../../Fuzz/Regressions/tags-m4a/item-past-the-end.m4a"]].URLByStandardizingPath;
    AudioFileHandle *handle = [[AudioFileHandle alloc] initParserForReading:url error:NULL];
    XCTAssertNotNil(handle, @"CoreAudio opens it");
    XCTAssertFalse(handle.infoDictionaryReadable);
    AudioTrackMetadata *metadata = Parse(url, NULL);
    XCTAssertTrue(metadata.parsedOK);
    XCTAssertEqualObjects(metadata.title, @"item-past-the-end", @"the filename stands in");
    XCTAssertNil(metadata.artist);

    NSURL *tagged = [self write:VibeTagFixtureM4A art:nil];
    XCTAssertTrue([[AudioFileHandle alloc] initParserForReading:tagged error:NULL].infoDictionaryReadable,
                  @"a well-formed item list is read");
}

// The fuzz's file is refused at its moov, which runs past the end. These
// stay inside moov and the file: the first item's first atom runs past its
// item, then the first item runs past the list.
- (void)testMP4ItemOrItsDataPastItsParentIsSkipped {
    NSURL *url = [self write:VibeTagFixtureM4A art:nil];
    NSData *original = [NSData dataWithContentsOfURL:url];
    NSRange found = [original rangeOfData:[@"ilst" dataUsingEncoding:NSASCIIStringEncoding] options:0
                                    range:NSMakeRange(0, original.length)];
    XCTAssertNotEqual(found.location, (NSUInteger)NSNotFound, @"the fixture carries an item list");
    const uint8_t *bytes = (const uint8_t *)original.bytes;
    NSUInteger list = found.location - 4, item = list + 8;
    uint32_t listSize = OSReadBigInt32(bytes, list), itemSize = OSReadBigInt32(bytes, item);
    XCTAssertLessThanOrEqual(OSReadBigInt32(bytes, item + 8), itemSize - 8, @"the first item holds an atom");
    XCTAssertLessThan(item + itemSize + 8, list + listSize, @"another item follows the first");
    XCTAssertLessThanOrEqual(list + listSize + 8, original.length, @"the list is not the file's last 8 bytes");

    struct { NSUInteger at; uint32_t size; const char *label; } cases[] = {
            {item + 8, itemSize, "the item's first atom past its item"},
            {item, listSize, "the item past its list"},
    };
    for (const auto &patch : cases) {
        NSMutableData *data = [original mutableCopy];
        OSWriteBigInt32(data.mutableBytes, patch.at, patch.size);
        XCTAssertTrue([data writeToURL:url atomically:NO]);
        XCTAssertFalse([[AudioFileHandle alloc] initParserForReading:url error:NULL].infoDictionaryReadable,
                       @"%s", patch.label);
    }
}

- (void)testW64 {
    [self assertFixture:VibeTagFixtureW64 fileType:VibeAudioFileFormatW64 rate:44100 duration:0.5];
}

#pragma mark - Each field alone

// The field alone, in each format that carries it, so no other field's tag
// can answer for it. Ogg's formats need the render fixtures. Without them
// only FLAC's Xiph comment is read here.
- (void)assertFieldAlone:(VibeTagFixtureField)field {
    NSUInteger formats = 0;
    for (NSInteger index = 0; index < VibeTagFixtureCount; index++) {
        VibeTagFixture fixture = (VibeTagFixture)index;
        if (!VibeTagFixtureCarries(fixture, field)) {
            continue;
        }
        NSString *label = [NSString stringWithFormat:@"%@ alone in %@", VibeTagFixtureFieldName(field),
                                                     VibeTagFixtureName(fixture)];
        NSURL *url = VibeWriteTagFieldFixture(_dir, fixture, field);
        if (!url) {
            XCTAssertTrue(fixture == VibeTagFixtureVorbis || fixture == VibeTagFixtureOpus, @"%@", label);
            continue;
        }
        AudioTrackMetadata *metadata = Parse(url, NULL);
        XCTAssertTrue(metadata.parsedOK, @"%@", label);
        NSIndexSet *tagged = [NSIndexSet indexSetWithIndex:(NSUInteger)field];
        [self assertFields:tagged of:metadata fixture:fixture label:label];
        [self assertFields:tagged of:CacheRoundTrip(metadata) fixture:fixture
                     label:[label stringByAppendingString:@" archived"]];
        formats++;
    }
    XCTAssertGreaterThan(formats, 0u, @"%@", VibeTagFixtureFieldName(field));
}

- (void)testAlbum { [self assertFieldAlone:VibeTagFixtureFieldAlbum]; }
- (void)testAlbumArtist { [self assertFieldAlone:VibeTagFixtureFieldAlbumArtist]; }
- (void)testGenre { [self assertFieldAlone:VibeTagFixtureFieldGenre]; }
- (void)testComposer { [self assertFieldAlone:VibeTagFixtureFieldComposer]; }
- (void)testYear { [self assertFieldAlone:VibeTagFixtureFieldYear]; }
- (void)testTrackNumberAndCount { [self assertFieldAlone:VibeTagFixtureFieldTrack]; }
- (void)testDiscNumberAndCount { [self assertFieldAlone:VibeTagFixtureFieldDisc]; }
- (void)testCompilation { [self assertFieldAlone:VibeTagFixtureFieldCompilation]; }
- (void)testMusicBrainzReleaseID { [self assertFieldAlone:VibeTagFixtureFieldReleaseID]; }
- (void)testMusicBrainzRecordingID { [self assertFieldAlone:VibeTagFixtureFieldRecordingID]; }
- (void)testISRC { [self assertFieldAlone:VibeTagFixtureFieldISRC]; }
- (void)testReplayGainTrackGain { [self assertFieldAlone:VibeTagFixtureFieldReplayGainTrackGain]; }
- (void)testReplayGainTrackPeak { [self assertFieldAlone:VibeTagFixtureFieldReplayGainTrackPeak]; }
- (void)testReplayGainAlbumGain { [self assertFieldAlone:VibeTagFixtureFieldReplayGainAlbumGain]; }
- (void)testReplayGainAlbumPeak { [self assertFieldAlone:VibeTagFixtureFieldReplayGainAlbumPeak]; }
- (void)testR128TrackGain { [self assertFieldAlone:VibeTagFixtureFieldR128TrackGain]; }
- (void)testR128AlbumGain { [self assertFieldAlone:VibeTagFixtureFieldR128AlbumGain]; }
- (void)testSoundCheck { [self assertFieldAlone:VibeTagFixtureFieldSoundCheck]; }
- (void)testComment { [self assertFieldAlone:VibeTagFixtureFieldComment]; }
- (void)testGrouping { [self assertFieldAlone:VibeTagFixtureFieldGrouping]; }
- (void)testLabel { [self assertFieldAlone:VibeTagFixtureFieldLabel]; }
- (void)testCatalogNumber { [self assertFieldAlone:VibeTagFixtureFieldCatalogNumber]; }
- (void)testConductor { [self assertFieldAlone:VibeTagFixtureFieldConductor]; }
- (void)testRemixer { [self assertFieldAlone:VibeTagFixtureFieldRemixer]; }
- (void)testLyricist { [self assertFieldAlone:VibeTagFixtureFieldLyricist]; }
- (void)testMood { [self assertFieldAlone:VibeTagFixtureFieldMood]; }
- (void)testLanguage { [self assertFieldAlone:VibeTagFixtureFieldLanguage]; }
- (void)testCopyright { [self assertFieldAlone:VibeTagFixtureFieldCopyright]; }
- (void)testOriginalDate { [self assertFieldAlone:VibeTagFixtureFieldOriginalDate]; }
- (void)testTitleSort { [self assertFieldAlone:VibeTagFixtureFieldTitleSort]; }
- (void)testArtistSort { [self assertFieldAlone:VibeTagFixtureFieldArtistSort]; }
- (void)testAlbumSort { [self assertFieldAlone:VibeTagFixtureFieldAlbumSort]; }
- (void)testAlbumArtistSort { [self assertFieldAlone:VibeTagFixtureFieldAlbumArtistSort]; }

// A file tagged with its title alone reads no comment, grouping, or label.
- (void)testAFileWithNoneOfTheFieldsReadsNone {
    for (NSNumber *each in @[@(VibeTagFixtureMP3ID3v24), @(VibeTagFixtureM4A), @(VibeTagFixtureFLAC),
                             @(VibeTagFixtureVorbis), @(VibeTagFixtureOpus)]) {
        VibeTagFixture fixture = (VibeTagFixture)each.integerValue;
        NSString *name = VibeTagFixtureName(fixture);
        NSURL *url = [_dir URLByAppendingPathComponent:name];
        if (!VibeWriteTagFixtureAudio(url, fixture)) {
            XCTAssertTrue(fixture == VibeTagFixtureVorbis || fixture == VibeTagFixtureOpus, @"%@", name);
            continue;
        }
        TagLib::PropertyMap properties;
        properties["TITLE"] = TagLib::StringList(VibeTagString(kVibeTagTitle));
        XCTAssertTrue(VibeSaveTagFixtureTags(url, fixture, properties, nil, NO), @"%@", name);
        AudioTrackMetadata *metadata = Parse(url, NULL);
        XCTAssertTrue(metadata.parsedOK, @"%@", name);
        XCTAssertEqualObjects(metadata.title, kVibeTagTitle, @"%@", name);
        for (AudioTrackMetadata *read in @[metadata, CacheRoundTrip(metadata)]) {
            XCTAssertNil(read.comment, @"%@", name);
            XCTAssertNil(read.grouping, @"%@", name);
            XCTAssertNil(read.label, @"%@", name);
            XCTAssertNil(read.extraTags, @"%@: no extra tag costs no dictionary", name);
            XCTAssertEqual(read.bitDepth, FixtureBitDepth(fixture), @"%@", name);
        }
    }
}

// Writes `properties` over the fixture's own tags, through TagLib.
static void Retag(NSURL *url, VibeTagFixture fixture, NSDictionary<NSString *, NSString *> *properties) {
    TagLib::PropertyMap map;
    for (NSString *key in properties) {
        map[key.UTF8String] = TagLib::StringList(VibeTagString(properties[key]));
    }
    VibeSaveTagFixtureTags(url, fixture, map, nil, NO);
}

// ID3v2's TIT1 is the grouping when GRP1 is absent, as before iTunes 12.5.
// GRP1 wins. MP4's and a Xiph comment's WORK is the work, never the grouping.
- (void)testTheGroupingsOtherKeys {
    for (NSNumber *each in @[@(VibeTagFixtureMP3ID3v23), @(VibeTagFixtureMP3ID3v24), @(VibeTagFixtureWAVID3),
                             @(VibeTagFixtureAIFF)]) {
        VibeTagFixture fixture = (VibeTagFixture)each.integerValue;
        NSString *name = VibeTagFixtureName(fixture);
        NSURL *url = VibeWriteTagFieldFixture(_dir, fixture, VibeTagFixtureFieldAlbum);
        XCTAssertNotNil(url, @"%@", name);
        Retag(url, fixture, @{@"WORK": @"Old Grouping"});
        XCTAssertEqualObjects(Parse(url, NULL).grouping, @"Old Grouping", @"%@: TIT1 alone", name);
        Retag(url, fixture, @{@"WORK": @"Old Grouping", @"GROUPING": kVibeTagGrouping});
        AudioTrackMetadata *metadata = Parse(url, NULL);
        XCTAssertEqualObjects(metadata.grouping, kVibeTagGrouping, @"%@: GRP1 wins", name);
        XCTAssertEqualObjects(CacheRoundTrip(metadata).grouping, kVibeTagGrouping, @"%@ archived", name);
    }
    for (NSNumber *each in @[@(VibeTagFixtureM4A), @(VibeTagFixtureFLAC), @(VibeTagFixtureVorbis)]) {
        VibeTagFixture fixture = (VibeTagFixture)each.integerValue;
        NSURL *url = VibeWriteTagFieldFixture(_dir, fixture, VibeTagFixtureFieldAlbum);
        if (!url) {
            XCTAssertEqual(fixture, VibeTagFixtureVorbis);
            continue;
        }
        Retag(url, fixture, @{@"WORK": @"A Work"});
        XCTAssertNil(Parse(url, NULL).grouping, @"%@", VibeTagFixtureName(fixture));
    }
}

// A Xiph comment may hold the comment as DESCRIPTION, and the label as
// ORGANIZATION or PUBLISHER. COMMENT and LABEL win.
- (void)testTheCommentsAndTheLabelsOtherKeys {
    for (NSNumber *each in @[@(VibeTagFixtureFLAC), @(VibeTagFixtureVorbis), @(VibeTagFixtureOpus)]) {
        VibeTagFixture fixture = (VibeTagFixture)each.integerValue;
        NSString *name = VibeTagFixtureName(fixture);
        NSURL *url = VibeWriteTagFieldFixture(_dir, fixture, VibeTagFixtureFieldAlbum);
        if (!url) {
            XCTAssertNotEqual(fixture, VibeTagFixtureFLAC);
            continue;
        }
        Retag(url, fixture, @{@"DESCRIPTION": @"Described", @"ORGANIZATION": @"Organization"});
        AudioTrackMetadata *metadata = Parse(url, NULL);
        XCTAssertEqualObjects(metadata.comment, @"Described", @"%@", name);
        XCTAssertEqualObjects(metadata.label, @"Organization", @"%@", name);
        Retag(url, fixture, @{@"PUBLISHER": @"Publisher"});
        XCTAssertEqualObjects(Parse(url, NULL).label, @"Publisher", @"%@", name);
        Retag(url, fixture, @{@"COMMENT": kVibeTagComment, @"DESCRIPTION": @"Described",
                              @"LABEL": kVibeTagLabel, @"ORGANIZATION": @"Organization", @"PUBLISHER": @"Publisher"});
        metadata = Parse(url, NULL);
        XCTAssertEqualObjects(metadata.comment, kVibeTagComment, @"%@", name);
        XCTAssertEqualObjects(metadata.label, kVibeTagLabel, @"%@", name);
    }
}

// A Xiph comment or a TXXX frame may name the original date ORIGINALYEAR.
// ORIGINALDATE wins. A tag of blanks is untagged, never empty.
- (void)testTheOriginalDatesOtherKeyAndBlankExtras {
    for (NSNumber *each in @[@(VibeTagFixtureMP3ID3v24), @(VibeTagFixtureFLAC), @(VibeTagFixtureVorbis)]) {
        VibeTagFixture fixture = (VibeTagFixture)each.integerValue;
        NSString *name = VibeTagFixtureName(fixture);
        NSURL *url = VibeWriteTagFieldFixture(_dir, fixture, VibeTagFixtureFieldAlbum);
        if (!url) {
            XCTAssertEqual(fixture, VibeTagFixtureVorbis);
            continue;
        }
        Retag(url, fixture, @{@"ORIGINALYEAR": @"1968"});
        AudioTrackMetadata *metadata = Parse(url, NULL);
        XCTAssertEqualObjects([metadata extraTag:VibeTagFieldOriginalDate], @"1968", @"%@", name);
        XCTAssertEqual(metadata.originalYear, 1968, @"%@", name);
        Retag(url, fixture, @{@"ORIGINALYEAR": @"1968", @"ORIGINALDATE": kVibeTagOriginalDate});
        XCTAssertEqualObjects([Parse(url, NULL) extraTag:VibeTagFieldOriginalDate], kVibeTagOriginalDate, @"%@", name);
        Retag(url, fixture, @{@"CONDUCTOR": @"   ", @"MOOD": @"Mellow"});
        metadata = Parse(url, NULL);
        XCTAssertNil([metadata extraTag:VibeTagFieldConductor], @"%@", name);
        XCTAssertEqualObjects(metadata.extraTags, @{VibeTagFieldMood: @"Mellow"}, @"%@", name);
    }
}

#pragma mark - Bit depth

// Writes `buffer` as audio of `codec` at `depth` bits, in the container the
// extension names, with Apple's encoder.
static NSURL *EncodeLossless(NSURL *url, AudioFormatID codec, NSInteger depth) {
    NSError *error = nil;
    @autoreleasepool {
        AVAudioFile *file = [[AVAudioFile alloc] initForWriting:url
                                                       settings:@{AVFormatIDKey: @(codec), AVSampleRateKey: @44100,
                                                                  AVNumberOfChannelsKey: @2,
                                                                  AVEncoderBitDepthHintKey: @(depth)}
                                                   commonFormat:AVAudioPCMFormatFloat32
                                                    interleaved:YES error:&error];
        if (![file writeFromBuffer:VibeToneBuffer(22050, 44100, 2, AVAudioPCMFormatFloat32) error:&error]) {
            return nil;
        }
    }
    return url;
}

// Deeper streams than the fixtures': 24-bit FLAC and ALAC, float WAV, ALAC in
// CAF, which CoreAudio's facts read, and FLAC in MP4, whose kind is its codec's.
- (void)testTheBitDepthOfDeeperStreams {
    NSError *error = nil;
    AVAudioPCMBuffer *floats = VibeToneBuffer(22050, 44100, 2, AVAudioPCMFormatFloat32);
    NSDictionary<NSString *, NSArray *> *cases = @{
            @"deep.flac": @[VibeWriteFixture([_dir URLByAppendingPathComponent:@"deep.flac"], floats, &error) ?: NSNull.null,
                            @24, VibeAudioFileFormatFLAC],
            @"float.wav": @[VibeWriteFixture([_dir URLByAppendingPathComponent:@"float.wav"], floats, &error) ?: NSNull.null,
                            @32, VibeAudioFileFormatWAV],
            @"deep.m4a": @[EncodeLossless([_dir URLByAppendingPathComponent:@"deep.m4a"], kAudioFormatAppleLossless, 24)
                                   ?: NSNull.null, @24, VibeAudioFileFormatALAC],
            @"flac.m4a": @[EncodeLossless([_dir URLByAppendingPathComponent:@"flac.m4a"], kAudioFormatFLAC, 24)
                                   ?: NSNull.null, @24, VibeAudioFileFormatFLAC],
            @"alac.caf": @[EncodeLossless([_dir URLByAppendingPathComponent:@"alac.caf"], kAudioFormatAppleLossless, 24)
                                   ?: NSNull.null, @24, VibeAudioFileFormatALAC],
    };
    for (NSString *name in cases) {
        NSURL *url = cases[name][0];
        XCTAssertTrue([url isKindOfClass:NSURL.class], @"%@: %@", name, error);
        if (![url isKindOfClass:NSURL.class]) continue;
        AudioTrackMetadata *metadata = Parse(url, NULL);
        XCTAssertTrue(metadata.parsedOK, @"%@", name);
        XCTAssertEqualObjects(metadata.fileType, cases[name][2], @"%@", name);
        XCTAssertEqual(metadata.bitDepth, [cases[name][1] integerValue], @"%@", name);
        XCTAssertEqual(CacheRoundTrip(metadata).bitDepth, [cases[name][1] integerValue], @"%@ archived", name);
    }
}

// STREAMINFO's MD5 is the decoded audio's. An encoder that computed none
// writes zeros, which read as no MD5.
- (void)testFLACAudioMD5 {
    NSURL *url = [self write:VibeTagFixtureFLAC art:sArt];
    XCTAssertEqualObjects(Parse(url, NULL).audioMD5, ToneMD5());
    NSMutableData *bytes = [NSMutableData dataWithContentsOfURL:url];
    // fLaC, the block header, then STREAMINFO, whose MD5 starts at its byte 18.
    XCTAssertEqual(memcmp((const uint8_t *)bytes.bytes + 26, ToneMD5().bytes, 16), 0, @"the fixture's layout moved");
    [bytes resetBytesInRange:NSMakeRange(26, 16)];
    XCTAssertTrue([bytes writeToURL:url atomically:NO]);
    AudioTrackMetadata *metadata = Parse(url, NULL);
    XCTAssertTrue(metadata.parsedOK);
    XCTAssertNil(metadata.audioMD5);
}

// A tag that holds no number reads as untagged, and a count may stand alone.
- (void)testUnreadableFieldValuesStayUntagged {
    NSURL *url = [self write:VibeTagFixtureFLAC art:sArt];
    {
        TagLib::FLAC::File file(url.fileSystemRepresentation);
        TagLib::PropertyMap properties = file.properties();
        for (const char *key : {"DATE", "TRACKNUMBER", "DISCNUMBER", "COMPILATION", "REPLAYGAIN_TRACK_GAIN",
                                "REPLAYGAIN_TRACK_PEAK", "R128_TRACK_GAIN"}) {
            properties[key] = TagLib::StringList("none");
        }
        properties["R128_ALBUM_GAIN"] = TagLib::StringList("40000");
        properties["DISCTOTAL"] = TagLib::StringList("0");
        properties["ALBUM"] = TagLib::StringList(" ");
        file.setProperties(properties);
        XCTAssertTrue(file.save());
    }
    AudioTrackMetadata *metadata = Parse(url, NULL);
    XCTAssertTrue(metadata.parsedOK);
    XCTAssertNil(metadata.album, @"whitespace is no album");
    XCTAssertEqual(metadata.year, 0);
    XCTAssertEqual(metadata.trackNumber, 0);
    XCTAssertEqual(metadata.trackCount, 12, @"its own tag still counts");
    XCTAssertEqual(metadata.discNumber, 0);
    XCTAssertEqual(metadata.discCount, 0);
    XCTAssertFalse(metadata.isCompilation);
    XCTAssertNil(metadata.replayGainTrackGain);
    XCTAssertNil(metadata.replayGainTrackPeak);
    XCTAssertNil(metadata.r128TrackGain);
    XCTAssertNil(metadata.r128AlbumGain, @"past Q7.8's range");
}

// Sound Check's louder channel sets the gain. All zero, or fewer than two
// words, is no gain.
- (void)testSoundCheckReadsTheLouderChannel {
    NSURL *url = [self write:VibeTagFixtureM4A art:sArt];
    NSDictionary<NSString *, NSNumber *> *cases = @{
            @" 000007D0 000003E8": @(kVibeTagSoundCheckGain),
            @"00000064 00000064 0 0 0 0 0 0 0 0": @(10.0),
            @" 00000000 00000000": @(NAN),
            @"000003E8": @(NAN),
            @"loud": @(NAN),
    };
    for (NSString *value in cases) {
        {
            TagLib::MP4::File file(url.fileSystemRepresentation);
            file.tag()->setItem("----:com.apple.iTunes:iTunNORM",
                                TagLib::MP4::Item(TagLib::StringList(VibeTagString(value))));
            XCTAssertTrue(file.save());
        }
        NSNumber *gain = Parse(url, NULL).soundCheckGain;
        if (isnan(cases[value].doubleValue)) {
            XCTAssertNil(gain, @"%@", value);
        }
        else {
            XCTAssertEqualWithAccuracy(gain.doubleValue, cases[value].doubleValue, 1e-9, @"%@", value);
        }
    }
}

#pragma mark - Tags beat analysis

// A tempo outside (0, 1000) and a key no spelling reads are untagged, so
// analysis fills both in.
- (void)testAnUnusableTempoOrKeyStaysUntagged {
    NSURL *url = [self write:VibeTagFixtureFLAC art:sArt];
    for (NSArray<NSString *> *values in @[@[@"5000", @"42"], @[@"-3", @"Q"], @[@"tempo", @""], @[@"0", @"13A"]]) {
        {
            TagLib::FLAC::File file(url.fileSystemRepresentation);
            TagLib::PropertyMap properties = file.properties();
            properties["BPM"] = TagLib::StringList(VibeTagString(values[0]));
            properties["INITIALKEY"] = TagLib::StringList(VibeTagString(values[1]));
            file.setProperties(properties);
            XCTAssertTrue(file.save());
        }
        AudioTrackMetadata *metadata = Parse(url, NULL);
        XCTAssertTrue(metadata.parsedOK, @"%@", values);
        XCTAssertEqual(metadata.bpm, 0.0f, @"%@", values);
        XCTAssertEqual(metadata.key, VibeMusicalKeyNone, @"%@", values);
    }
}

#pragma mark - Embedded art

// Art that cannot decode fails without a crash or a full-size allocation. The
// file still carries art, so the row is not artless; the bytes are marked
// undecodable, which lets the folder's cover stand in (this piece's AGENTS.md).
- (void)assertArtFailsCleanly:(NSData *)art named:(NSString *)label {
    for (NSNumber *fixture in @[@(VibeTagFixtureMP3ID3v24), @(VibeTagFixtureFLAC)]) {
        NSURL *url = [self write:(VibeTagFixture)fixture.integerValue art:art];
        NSString *name = [NSString stringWithFormat:@"%@ in %@", label, url.lastPathComponent];
        NSData *displayArt = nil;
        AudioTrackMetadata *metadata = Parse(url, &displayArt);
        XCTAssertTrue(metadata.parsedOK, @"%@", name);
        XCTAssertEqualObjects(metadata.title, kVibeTagTitle, @"%@", name);
        XCTAssertTrue(metadata.artwork.hasEmbeddedArt, @"%@: not artless", name);
        XCTAssertNil(metadata.artwork.encodedThumbnailDataForStorage, @"%@", name);
        XCTAssertNil(displayArt, @"%@", name);
        XCTAssertNil([metadata.artwork loadArtBlocking], @"%@", name);
        XCTAssertFalse(metadata.artNeedsLoad, @"%@: undecodable bytes are not retried", name);
        // The second file meets the first's picture in the share, and still
        // lets go of its own bytes.
        XCTAssertNil([metadata.artwork artDataForArchivedDisplayArt], @"%@: its bytes are let go", name);

        // The archived entry still says the file has art.
        NSError *error = nil;
        NSData *archive = [NSKeyedArchiver archivedDataWithRootObject:metadata requiringSecureCoding:YES
                                                                error:&error];
        AudioTrackMetadata *restored = [NSKeyedUnarchiver unarchivedObjectOfClass:AudioTrackMetadata.class
                                                                         fromData:archive error:&error];
        XCTAssertNotNil(restored, @"%@: %@", name, error);
        XCTAssertTrue(restored.artwork.hasEmbeddedArt, @"%@", name);

        NSData *extracted = nil;
        XCTAssertEqual(Extract(url, &extracted), VibeEmbeddedArtExtractionFoundArt, @"%@", name);
        XCTAssertEqualObjects(extracted, art, @"%@", name);
    }
}

- (void)testUndecodableArtFailsCleanly {
    [self assertArtFailsCleanly:VibeTagUndecodableArt() named:@"garbage after a JPEG header"];
}

- (void)testArtDeclaringAHugeImageFailsCleanly {
    [self assertArtFailsCleanly:VibeTagOversizeArt(60000) named:@"a JPEG declaring 60000px"];
}

// A header ImageIO accepts decodes at the bound, never at its declared size.
- (void)testArtDeclaringALargeImageDecodesAtTheBound {
    NSData *art = VibeTagOversizeArt(8000);
    XCTAssertEqual(VibeEncodedImagePixelSize(art).width, 8000);
    NSData *displayArt = nil;
    AudioTrackMetadata *metadata = Parse([self write:VibeTagFixtureFLAC art:art], &displayArt);
    XCTAssertTrue(metadata.artwork.hasEmbeddedArt);
    CGSize thumbnail = VibeEncodedImagePixelSize(metadata.artwork.encodedThumbnailDataForStorage);
    XCTAssertEqual(thumbnail.width, kVibeThumbnailArtDimension);
    XCTAssertEqual(VibeEncodedImagePixelSize(displayArt).width, kVibeArchivedDisplayArtDimension);
    XCTAssertEqual([metadata.artwork loadArtBlocking].size.width, kVibeDisplayArtDimension);
}

// Larger art is downscaled for the rendition, aspect kept.
- (void)testLargeArtArchivesABoundedRendition {
    NSData *art = VibeImageOfColor(1500, 0.8, 0.2, 0.3, UTTypeJPEG);
    NSData *displayArt = nil;
    AudioTrackMetadata *metadata = Parse([self write:VibeTagFixtureM4A art:art], &displayArt);
    XCTAssertTrue(metadata.artwork.hasEmbeddedArt);
    CGSize size = VibeEncodedImagePixelSize(displayArt);
    XCTAssertEqual(size.width, kVibeArchivedDisplayArtDimension);
    XCTAssertEqual(size.height, kVibeArchivedDisplayArtDimension);
}

// Two files that embed one picture, as an album's tracks do, share its
// archived forms: the second parse decodes nothing (ArchivedArtShare.h).
- (void)testFilesEmbeddingOnePictureShareItsForms {
    NSData *art = VibeImageOfColor(1400, 0.1, 0.6, 0.4, UTTypeJPEG);
    NSURL *first = [self write:VibeTagFixtureFLAC art:art];
    NSURL *second = [_dir URLByAppendingPathComponent:@"second.flac"];
    XCTAssertTrue([NSFileManager.defaultManager copyItemAtURL:first toURL:second error:NULL]);
    NSData *firstArt = nil, *secondArt = nil;
    AudioTrackMetadata *one = Parse(first, &firstArt);
    AudioTrackMetadata *two = Parse(second, &secondArt);
    XCTAssertNotNil(firstArt);
    XCTAssertEqual(firstArt, secondArt, @"the same rendition, made once");
    XCTAssertEqualObjects(one.artwork.encodedThumbnailDataForStorage, two.artwork.encodedThumbnailDataForStorage);
}

// A read that fails is unknown, never artless: the folder's cover must not
// replace art the file may still carry.
- (void)testAFailedArtReadIsNotArtless {
    NSData *art = nil;
    XCTAssertEqual(Extract([_dir URLByAppendingPathComponent:@"missing.flac"], &art),
                   VibeEmbeddedArtExtractionReadFailed);
    NSURL *locked = [self write:VibeTagFixtureFLAC art:sArt];
    XCTAssertTrue([NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions: @0}
                                                 ofItemAtPath:locked.path error:NULL]);
    XCTAssertEqual(Extract(locked, &art), VibeEmbeddedArtExtractionReadFailed);
    XCTAssertNil(art);

    // A cache hit whose file has since gone.
    AudioTrackArtwork *artwork = [[AudioTrackArtwork alloc]
            initWithSourceFilePath:[_dir URLByAppendingPathComponent:@"missing.flac"].path
                         extractor:VibeTagLibArtExtractor()];
    artwork.folderArt = nil;
    [artwork adoptArchivedThumbnailData:nil hasEmbeddedArt:YES];
    XCTAssertNil([artwork loadArtBlocking]);
    XCTAssertTrue(artwork.hasEmbeddedArt);
}

// A remote placeholder's tags and art come through its backend's read, by
// range. Its own direct open fails.
- (void)testARemotePlaceholderIsReadThroughItsBackend {
    NSURL *source = [self write:VibeTagFixtureFLAC art:sArt];
    NSData *bytes = [NSData dataWithContentsOfURL:source];
    NSURL *root = [_dir URLByAppendingPathComponent:@"remote" isDirectory:YES];
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:root withIntermediateDirectories:YES
                                                          attributes:nil error:NULL]);
    NSURL *placeholder = [root URLByAppendingPathComponent:source.lastPathComponent];
    int fd = open(placeholder.fileSystemRepresentation, O_CREAT | O_WRONLY | O_TRUNC, 0600);
    XCTAssertTrue(fd >= 0 && ftruncate(fd, (off_t)bytes.length) == 0 && fchmod(fd, 0) == 0);
    close(fd);
    __block NSUInteger reads = 0;
    [CloudFileMaterializer setRemoteRoot:root fetch:^BOOL(NSURL *url, dispatch_block_t onReadable,
                                                          void (^onCancel)(dispatch_block_t), NSError **error) {
        return NO;
    } read:^NSData *(NSURL *url, uint64_t offset, uint64_t length, NSError **error) {
        reads++;
        return offset + length <= bytes.length ? [bytes subdataWithRange:NSMakeRange(offset, length)] : nil;
    } availability:nil];
    AudioTrackMetadata *metadata = Parse(placeholder, NULL);
    NSData *art = nil;
    VibeEmbeddedArtExtractionResult extracted = Extract(placeholder, &art);
    [CloudFileMaterializer setRemoteRoot:nil fetch:nil read:nil availability:nil];

    XCTAssertTrue(metadata.parsedOK);
    XCTAssertEqualObjects(metadata.title, kVibeTagTitle);
    XCTAssertTrue(metadata.artwork.hasEmbeddedArt);
    XCTAssertEqual(extracted, VibeEmbeddedArtExtractionFoundArt);
    XCTAssertEqualObjects(art, sArt);
    XCTAssertGreaterThanOrEqual(reads, 2u, @"one per parse at least");
}

#pragma mark - Detection

- (NSURL *)rename:(NSURL *)url to:(NSString *)name {
    NSURL *renamed = [_dir URLByAppendingPathComponent:name];
    XCTAssertTrue([NSFileManager.defaultManager moveItemAtURL:url toURL:renamed error:NULL]);
    return renamed;
}

// The extension's parser refuses the file, so the content sniff decides.
- (void)testAWrongExtensionFallsBackToTheContent {
    NSDictionary<NSString *, VibeAudioFileFormat> *cases = @{
            @"m4a-as.flac": VibeAudioFileFormatAAC,
            @"wav-as.m4a": VibeAudioFileFormatWAV,
            @"wav-as.flac": VibeAudioFileFormatWAV,
            @"aiff-as.m4a": VibeAudioFileFormatAIFF,
            @"mp3-as.m4a": VibeAudioFileFormatMP3,
            @"flac-as.m4a": VibeAudioFileFormatFLAC,
    };
    NSDictionary<NSString *, NSNumber *> *sources = @{
            @"m4a-as.flac": @(VibeTagFixtureM4A), @"wav-as.m4a": @(VibeTagFixtureWAVID3),
            @"wav-as.flac": @(VibeTagFixtureWAVID3), @"aiff-as.m4a": @(VibeTagFixtureAIFF),
            @"mp3-as.m4a": @(VibeTagFixtureMP3ID3v24), @"flac-as.m4a": @(VibeTagFixtureFLAC),
    };
    for (NSString *name in cases) {
        NSURL *url = [self rename:[self write:(VibeTagFixture)sources[name].integerValue art:sArt] to:name];
        AudioTrackMetadata *metadata = Parse(url, NULL);
        XCTAssertEqualObjects(metadata.fileType, cases[name], @"%@", name);
        XCTAssertEqualObjects(metadata.title, kVibeTagTitle, @"%@", name);
    }
}

- (void)testNoExtensionSniffsTheContent {
    NSDictionary<NSNumber *, VibeAudioFileFormat> *cases = @{
            @(VibeTagFixtureFLAC): VibeAudioFileFormatFLAC, @(VibeTagFixtureMP3ID3v24): VibeAudioFileFormatMP3,
            @(VibeTagFixtureM4A): VibeAudioFileFormatAAC, @(VibeTagFixtureWAVID3): VibeAudioFileFormatWAV,
            @(VibeTagFixtureAIFF): VibeAudioFileFormatAIFF,
    };
    for (NSNumber *fixture in cases) {
        NSString *name = [VibeTagFixtureName((VibeTagFixture)fixture.integerValue)
                stringByReplacingOccurrencesOfString:@"." withString:@"-"];
        NSURL *url = [self rename:[self write:(VibeTagFixture)fixture.integerValue art:sArt] to:name];
        XCTAssertEqualObjects(Parse(url, NULL).title, kVibeTagTitle, @"%@", name);
    }
}

// TagLib's FLAC reader skips a leading ID3v2 tag, and so does its sniff.
- (void)testAFLACWithAnID3v2PrefixReadsAsFLAC {
    NSURL *flac = [self write:VibeTagFixtureFLAC art:sArt];
    NSMutableData *bytes = [NSMutableData dataWithBytes:"ID3\x04\x00\x00\x00\x00\x00\x40" length:10];
    [bytes increaseLengthBy:64];
    [bytes appendData:[NSData dataWithContentsOfURL:flac]];
    for (NSString *name in @[@"prefixed.flac", @"prefixed"]) {
        NSURL *url = [_dir URLByAppendingPathComponent:name];
        XCTAssertTrue([bytes writeToURL:url atomically:YES]);
        AudioTrackMetadata *metadata = Parse(url, NULL);
        XCTAssertEqualObjects(metadata.title, kVibeTagTitle, @"%@", name);
        XCTAssertEqual(metadata.key, VibeMusicalKeyMake(9, YES), @"%@", name);
        XCTAssertEqualWithAccuracy(metadata.duration, 0.5, 0.06, @"%@", name);
        XCTAssertTrue(metadata.artwork.hasEmbeddedArt, @"%@", name);
    }
}

// FLAC in Ogg carries "fLaC" in its first page. Playback refuses it, so the
// parse must too, by extension and by content.
- (void)testFLACInOggIsAFailedParse {
    NSMutableData *bytes = [NSMutableData dataWithBytes:"OggS" length:4];
    [bytes increaseLengthBy:24];
    [bytes appendBytes:"\x7F" "FLAC\x01\x00\x00\x01" "fLaC\x80\x00\x00\x22" length:17];
    [bytes increaseLengthBy:34];
    for (NSString *name in @[@"ogg.flac", @"ogg.oga", @"ogg"]) {
        NSURL *url = [_dir URLByAppendingPathComponent:name];
        XCTAssertTrue([bytes writeToURL:url atomically:YES]);
        AudioTrackMetadata *metadata = Parse(url, NULL);
        XCTAssertFalse(metadata.parsedOK, @"%@", name);
        XCTAssertEqualObjects(metadata.title, name.stringByDeletingPathExtension, @"%@", name);
    }
}

@end
