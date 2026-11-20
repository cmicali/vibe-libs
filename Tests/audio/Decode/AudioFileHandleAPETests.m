//
//  AudioFileHandleAPETests.m
//
//  Monkey's Audio through the handle: each compression level and sample
//  width decoded bit for bit, the facts, the seeks, a file cut short, a
//  damaged frame, an ID3v2 tag before the descriptor, and an image with its
//  CUE sheet. The fixtures in APE/ are a signal this file computes
//  (APEFixtureSample), encoded by the SDK's own encoder
//  (make-ape-fixtures.py), so every sample is checked against the formula.
//

#import <XCTest/XCTest.h>
#import <AVFoundation/AVFoundation.h>

#import "AudioFileHandle.h"
#import "CueWindowMath.h"
#import "VibePlaylistEntry.h"
#import "VibePlaylistFile.h"

// make-ape-fixtures.py's sample16: a triangle and two bits of hashed noise,
// in [-8194, 8192].
static int32_t APEFixtureSample(int64_t frame, uint32_t channel) {
    uint32_t phase = (uint32_t)((uint64_t)frame * (300 + 97 * channel)) & 0xFFFF;
    int32_t triangle = phase < 32768 ? (int32_t)phase : 65535 - (int32_t)phase;
    uint32_t hash = (uint32_t)frame * 2654435761u + channel * 40503u;
    return (triangle >> 1) - 8192 + (int32_t)((hash >> 16) & 3) - 2;
}

// The float the decode gives for a fixture of `bits`: exact at every width,
// since each scale is a power of two. 8-bit keeps the top bits.
static float APEFixtureFloat(int64_t frame, uint32_t channel, uint32_t bits) {
    int32_t sample = APEFixtureSample(frame, channel);
    return bits == 8 ? (float)(sample >> 7) / 128.0f : (float)sample / 32768.0f;
}

@interface AudioFileHandleAPETests : XCTestCase
@property (strong) NSURL *directory;
@end

@implementation AudioFileHandleAPETests

- (void)setUp {
    [super setUp];
    self.directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]
                                isDirectory:YES];
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:self.directory withIntermediateDirectories:YES
                                                          attributes:nil error:NULL]);
}

- (void)tearDown {
    [NSFileManager.defaultManager removeItemAtURL:self.directory error:NULL];
    [super tearDown];
}

- (NSURL *)fixture:(NSString *)name {
    NSURL *url = [[NSBundle bundleForClass:self.class] URLForResource:name withExtension:@"ape"];
    XCTAssertNotNil(url, @"%@.ape is not in the bundle", name);
    return url;
}

- (AudioFileHandle *)open:(NSURL *)url {
    NSError *error = nil;
    AudioFileHandle *handle = [[AudioFileHandle alloc] initForReading:url error:&error];
    XCTAssertNotNil(handle, @"%@: %@", url.lastPathComponent, error);
    XCTAssertEqualObjects(handle.decoderName, @"MACLib", @"%@", url.lastPathComponent);
    return handle;
}

// Reads from the cursor in chunks of `chunk` until a read delivers nothing
// or `limit` frames, checking each sample against the formula from `start`.
// Answers the frames read.
- (int64_t)check:(AudioFileHandle *)handle from:(int64_t)start limit:(int64_t)limit chunk:(AVAudioFrameCount)chunk
            bits:(uint32_t)bits context:(NSString *)context {
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:handle.processingFormat frameCapacity:chunk];
    uint32_t channels = handle.processingFormat.channelCount;
    BOOL interleaved = handle.processingFormat.isInterleaved;
    int64_t read = 0;
    while (read < limit) {
        NSError *error = nil;
        AVAudioFrameCount wanted = (AVAudioFrameCount)MIN((int64_t)chunk, limit - read);
        XCTAssertTrue([handle readIntoBuffer:buffer frameCount:wanted error:&error], @"%@: %@", context, error);
        if (buffer.frameLength == 0) {
            break;
        }
        for (AVAudioFrameCount f = 0; f < buffer.frameLength; f++) {
            for (uint32_t c = 0; c < channels; c++) {
                float got = interleaved ? buffer.floatChannelData[0][f * channels + c] : buffer.floatChannelData[c][f];
                float expected = APEFixtureFloat(start + read + f, c, bits);
                if (got != expected) {
                    XCTFail(@"%@: frame %lld channel %u is %g, expected %g", context, start + read + f, c, got, expected);
                    return read;
                }
            }
        }
        read += buffer.frameLength;
    }
    return read;
}

#pragma mark - Levels, widths, and facts

// Fast through Insane, 16-bit stereo at 44.1 kHz. The source depth is the
// lossless formats' flag, and the packet is one of the file's frames.
- (void)testEachLevelDecodesBitForBit {
    NSDictionary<NSString *, NSNumber *> *framesPerPacket = @{
        @"level-fast": @73728, @"level-normal": @73728, @"level-high": @73728,
        @"level-extrahigh": @(73728 * 4), @"level-insane": @(73728 * 16),
    };
    for (NSString *name in framesPerPacket) {
        AudioFileHandle *handle = [self open:[self fixture:name]];
        const AudioStreamBasicDescription *file = handle.fileFormat.streamDescription;
        XCTAssertEqual(file->mFormatID, (AudioFormatID)'APE ', @"%@", name);
        XCTAssertEqual(file->mFormatFlags, kAppleLosslessFormatFlag_16BitSourceData, @"%@", name);
        XCTAssertEqual(file->mFramesPerPacket, framesPerPacket[name].unsignedIntValue, @"%@", name);
        XCTAssertEqual(handle.fileFormat.sampleRate, 44100, @"%@", name);
        XCTAssertEqual(handle.fileFormat.channelCount, 2u, @"%@", name);
        XCTAssertEqual(handle.length, 11025, @"%@", name);
        XCTAssertEqual([self check:handle from:0 limit:INT64_MAX chunk:4096 bits:16 context:name], 11025, @"%@", name);
        XCTAssertEqual(handle.framePosition, 11025, @"%@", name);
    }
}

// 8, 24, and 32-bit integers, 32-bit float, and an AIFF's big-endian
// samples, each to float32 exactly.
- (void)testEachSampleWidthDecodesBitForBit {
    NSDictionary<NSString *, NSArray<NSNumber *> *> *widths = @{
        @"depth8": @[@8, @(kAppleLosslessFormatFlag_16BitSourceData), @48000, @4800],
        @"depth24": @[@24, @(kAppleLosslessFormatFlag_24BitSourceData), @48000, @4800],
        @"depth32": @[@32, @(kAppleLosslessFormatFlag_32BitSourceData), @48000, @4800],
        @"float32": @[@32, @(kAppleLosslessFormatFlag_32BitSourceData), @48000, @4800],
        @"aiff16": @[@16, @(kAppleLosslessFormatFlag_16BitSourceData), @44100, @4410],
    };
    for (NSString *name in widths) {
        NSArray<NSNumber *> *facts = widths[name];
        AudioFileHandle *handle = [self open:[self fixture:name]];
        XCTAssertEqual(handle.fileFormat.streamDescription->mFormatFlags, facts[1].unsignedIntValue, @"%@", name);
        XCTAssertEqual(handle.fileFormat.sampleRate, facts[2].doubleValue, @"%@", name);
        XCTAssertEqual(handle.length, facts[3].longLongValue, @"%@", name);
        XCTAssertEqual([self check:handle from:0 limit:INT64_MAX chunk:1000 bits:facts[0].unsignedIntValue context:name],
                       facts[3].longLongValue, @"%@", name);
    }
}

// 5.1 keeps the source WAV's channel mask, read interleaved.
- (void)testSurroundKeepsItsChannelMask {
    NSError *error = nil;
    AudioFileHandle *handle = [[AudioFileHandle alloc] initForReading:[self fixture:@"surround51"] interleaved:YES
                                                                error:&error];
    XCTAssertNotNil(handle, @"%@", error);
    XCTAssertEqual(handle.fileFormat.channelCount, 6u);
    const AudioChannelLayout *layout = handle.fileFormat.channelLayout.layout;
    XCTAssertEqual(layout->mChannelLayoutTag, kAudioChannelLayoutTag_UseChannelBitmap);
    XCTAssertEqual(layout->mChannelBitmap, 0x3Fu);
    XCTAssertEqual([self check:handle from:0 limit:INT64_MAX chunk:777 bits:16 context:@"5.1"], 4800);
}

// An ID3v2 tag before the descriptor, which the sniff skips as the SDK does.
- (void)testAnID3v2TagBeforeTheDescriptorIsSkipped {
    AudioFileHandle *handle = [self open:[self fixture:@"id3v2-before"]];
    XCTAssertEqual(handle.length, 4410);
    XCTAssertEqual([self check:handle from:0 limit:INT64_MAX chunk:4096 bits:16 context:@"id3v2"], 4410);
}

#pragma mark - Seeks and frames

// Three and a half of Normal's frames, read in chunks that cross each frame.
- (void)testReadsAcrossTheFilesFrames {
    AudioFileHandle *handle = [self open:[self fixture:@"long"]];
    XCTAssertEqual(handle.length, 258048);
    XCTAssertEqual([self check:handle from:0 limit:INT64_MAX chunk:1001 bits:16 context:@"long"], 258048);
}

// Each seek restarts at the frame that holds its target, forward and back:
// a frame's first and last, the middle of one, and the last frame's end.
- (void)testSeeksLandOnTheirFrame {
    AudioFileHandle *handle = [self open:[self fixture:@"long"]];
    for (NSNumber *target in @[@100000, @0, @73727, @73728, @1, @221183, @147456, @258000, @50]) {
        NSError *error = nil;
        XCTAssertTrue([handle seekToFrame:target.longLongValue error:&error], @"%@: %@", target, error);
        XCTAssertEqual(handle.framePosition, target.longLongValue);
        int64_t expected = MIN(3000, 258048 - target.longLongValue);
        XCTAssertEqual([self check:handle from:target.longLongValue limit:3000 chunk:1024 bits:16
                           context:target.stringValue], expected);
    }
}

// A target at or past the end lands there and reads nothing. A seek back
// reads again.
- (void)testASeekPastTheEndReadsNothing {
    AudioFileHandle *handle = [self open:[self fixture:@"long"]];
    for (NSNumber *target in @[@258048, @999999]) {
        NSError *error = nil;
        XCTAssertTrue([handle seekToFrame:target.longLongValue error:&error], @"%@", error);
        XCTAssertEqual(handle.framePosition, 258048);
        XCTAssertEqual([self check:handle from:258048 limit:100 chunk:100 bits:16 context:@"end"], 0);
    }
    XCTAssertTrue([handle seekToFrame:258000 error:NULL]);
    XCTAssertEqual([self check:handle from:258000 limit:INT64_MAX chunk:100 bits:16 context:@"back"], 48);
}

#pragma mark - Damage

- (NSURL *)write:(NSData *)bytes named:(NSString *)name {
    NSURL *url = [self.directory URLByAppendingPathComponent:name];
    XCTAssertTrue([bytes writeToURL:url atomically:YES]);
    return url;
}

// A file cut short keeps its header's length. Its reads end at the last
// frame whose bytes are all there, each frame before it exact.
- (void)testAFileCutShortEndsWhereItsBytesDo {
    NSData *whole = [NSData dataWithContentsOfURL:[self fixture:@"long"]];
    NSURL *url = [self write:[whole subdataWithRange:NSMakeRange(0, whole.length * 6 / 10)] named:@"cut.ape"];
    AudioFileHandle *handle = [self open:url];
    XCTAssertEqual(handle.length, 258048);
    int64_t read = [self check:handle from:0 limit:INT64_MAX chunk:4096 bits:16 context:@"cut"];
    XCTAssertGreaterThan(read, 0);
    XCTAssertLessThan(read, 258048);
    XCTAssertEqual(read % 73728, 0, @"ends on a frame of the file's");
    // A seek past the bytes lands, and reads nothing.
    XCTAssertTrue([handle seekToFrame:250000 error:NULL]);
    XCTAssertEqual([self check:handle from:250000 limit:100 chunk:100 bits:16 context:@"past"], 0);
    // One cut inside its header opens nothing.
    XCTAssertNil([[AudioFileHandle alloc] initForReading:[self write:[whole subdataWithRange:NSMakeRange(0, 40)]
                                                                 named:@"head.ape"] error:NULL]);
}

// A frame whose bytes are damaged plays as silence, its own length, and the
// decode goes on, exact, from the next frame.
- (void)testADamagedFramePlaysAsSilence {
    NSMutableData *bytes = [[NSData dataWithContentsOfURL:[self fixture:@"long"]] mutableCopy];
    uint8_t *raw = bytes.mutableBytes;
    for (NSUInteger i = 70000; i < 70064; i++) {
        raw[i] ^= 0x5A;
    }
    AudioFileHandle *handle = [self open:[self write:bytes named:@"damaged.ape"]];
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:handle.processingFormat frameCapacity:4096];
    int64_t frame = 0, silent = 0;
    while (YES) {
        NSError *error = nil;
        XCTAssertTrue([handle readIntoBuffer:buffer error:&error], @"%@", error);
        if (buffer.frameLength == 0) {
            break;
        }
        for (AVAudioFrameCount f = 0; f < buffer.frameLength; f++, frame++) {
            float got = buffer.floatChannelData[0][f], expected = APEFixtureFloat(frame, 0, 16);
            if (got == 0 && expected != 0) {
                silent++;
            } else if (got != expected) {
                XCTFail(@"frame %lld is %g, expected %g or silence", frame, got, expected);
                return;
            }
        }
    }
    XCTAssertEqual(frame, 258048);
    XCTAssertGreaterThan(silent, 0, @"the damage was found");
    XCTAssertLessThanOrEqual(silent, 73728, @"one frame's worth at most");
}

- (void)testBytesThatAreNoMonkeysAudioFileAreRefused {
    NSMutableData *bytes = [NSMutableData dataWithBytes:"MAC \x96\x0f" length:6];
    [bytes increaseLengthBy:200];
    XCTAssertNil([[AudioFileHandle alloc] initForReading:[self write:bytes named:@"junk.ape"] error:NULL]);
}

#pragma mark - An image and its sheet

// The rip most often kept: one .ape for the album, beside a sheet that
// names the WAV it was made from. The sheet resolves to the .ape, and each
// track's window starts on its own samples.
- (void)testAnImageWithItsCUESheetPlaysEachTrackAtItsOffset {
    NSURL *image = [self.directory URLByAppendingPathComponent:@"Album.ape"];
    XCTAssertTrue([NSFileManager.defaultManager copyItemAtURL:[self fixture:@"long"] toURL:image error:NULL]);
    NSString *sheet = @"PERFORMER \"Seed Artist\"\nTITLE \"Seed Album\"\nFILE \"Album.wav\" WAVE\n"
                       "  TRACK 01 AUDIO\n    TITLE \"One\"\n    INDEX 01 00:00:00\n"
                       "  TRACK 02 AUDIO\n    TITLE \"Two\"\n    INDEX 01 00:02:00\n"
                       "  TRACK 03 AUDIO\n    TITLE \"Three\"\n    INDEX 01 00:04:37\n";
    NSURL *sheetURL = [self.directory URLByAppendingPathComponent:@"Album.cue"];
    XCTAssertTrue([sheet writeToURL:sheetURL atomically:YES encoding:NSUTF8StringEncoding error:NULL]);

    NSArray<VibePlaylistEntry *> *rows = [VibePlaylistFile cueEntriesForSheetAtURL:sheetURL knownFiles:nil];
    XCTAssertEqual(rows.count, 3u);
    AudioFileHandle *handle = [self open:image];
    // 00:02:00 is 88,200 frames at 44.1 kHz, and 00:04:37 is 4 s and 37/75.
    NSArray<NSNumber *> *starts = @[@0, @88200, @198156];
    int64_t previousEnd = 0;
    for (NSUInteger i = 0; i < rows.count; i++) {
        VibePlaylistEntry *row = rows[i];
        XCTAssertEqualObjects(row.url.lastPathComponent, @"Album.ape");
        NSRange window = VibeCueWindow(row.cueStart, row.cueEnd, handle.fileFormat.sampleRate, handle.length, NO);
        XCTAssertEqual((int64_t)window.location, starts[i].longLongValue, @"track %lu", (unsigned long)i + 1);
        XCTAssertEqual((int64_t)window.location, previousEnd, @"track %lu meets the one before", (unsigned long)i + 1);
        previousEnd = (int64_t)NSMaxRange(window);
        NSError *error = nil;
        XCTAssertTrue([handle seekToFrame:(AVAudioFramePosition)window.location error:&error], @"%@", error);
        XCTAssertEqual([self check:handle from:(int64_t)window.location limit:2000 chunk:512 bits:16
                           context:row.cueTitle ?: @"?"], 2000);
    }
    XCTAssertEqual(previousEnd, 258048, @"the last track runs to the image's end");
}

@end
