//
// The audio-open contract: AudioFileHandle's verdicts, facts, reads, cursor and
// descriptor ownership, and the stat-only NSURL check beside it.
//

#import <XCTest/XCTest.h>
#import <AVFoundation/AVFoundation.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#import "AudioFileHandle.h"
#import "AudioFileHandle+Debug.h"
#import "AudioFileFixtures.h"
#import "NSURL+Emptiness.h"

@interface AudioFileHandleTests : XCTestCase
@property (strong) NSURL *fixtureDirectory;
@end

@implementation AudioFileHandleTests

- (void)setUp {
    [super setUp];
    self.fixtureDirectory = [NSURL fileURLWithPath:[NSTemporaryDirectory()
            stringByAppendingPathComponent:NSUUID.UUID.UUIDString]
                                        isDirectory:YES];
    NSError *error = nil;
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:self.fixtureDirectory
                                          withIntermediateDirectories:YES
                                                           attributes:nil
                                                                error:&error], @"%@", error);
}

- (void)tearDown {
    [NSFileManager.defaultManager removeItemAtURL:self.fixtureDirectory error:nil];
    self.fixtureDirectory = nil;
    [super tearDown];
}

#pragma mark - Fixtures

// A 16-bit PCM WAV of `frames` frames, sample (n, c) = (n * 37 + c * 1000) % 20000 - 10000.
static int16_t VibeFixtureSample(uint32_t frame, uint32_t channel) {
    return (int16_t)(((int32_t)frame * 37 + (int32_t)channel * 1000) % 20000 - 10000);
}

- (NSURL *)writePCMNamed:(NSString *)name frames:(uint32_t)frames channels:(uint16_t)channels rate:(uint32_t)rate {
    NSMutableData *samples = [NSMutableData data];
    for (uint32_t frame = 0; frame < frames; frame++) {
        for (uint16_t channel = 0; channel < channels; channel++) {
            int16_t sample = VibeFixtureSample(frame, channel);
            [samples appendBytes:&sample length:2];
        }
    }
    NSURL *url = VibeWriteWAV([self.fixtureDirectory URLByAppendingPathComponent:name], samples, rate, channels, 16,
                              (uint32_t)samples.length);
    XCTAssertNotNil(url);
    return url;
}

// Silent MPEG-1 Layer III frames (320 kbps, 44.1 kHz, stereo) after a
// 1024-byte ID3v2.3 tag, with `gap` bytes between them that the tag does not
// declare — a defect taggers leave behind.
static NSData *VibeTaggedMP3WithGap(NSUInteger gap) {
    const uint8_t tag[10] = {'I', 'D', '3', 3, 0, 0, 0, 0, 8, 0};
    NSMutableData *bytes = [NSMutableData dataWithBytes:tag length:sizeof(tag)];
    [bytes increaseLengthBy:1024 + gap];
    const uint8_t header[4] = {0xFF, 0xFB, 0xE0, 0x00};
    for (int i = 0; i < 40; i++) {
        NSMutableData *frame = [NSMutableData dataWithLength:1044];
        [frame replaceBytesInRange:NSMakeRange(0, sizeof(header)) withBytes:header];
        [bytes appendData:frame];
    }
    return bytes;
}

static int VibeOpenDescriptorCount(void) {
    int count = 0, max = getdtablesize();
    for (int fd = 0; fd < max; fd++) {
        if (fcntl(fd, F_GETFD) != -1) {
            count++;
        }
    }
    return count;
}

// The process's descriptors open on this file.
static int VibeDescriptorsOpenOn(NSURL *url) {
    char resolved[PATH_MAX];
    if (!realpath(url.fileSystemRepresentation, resolved)) {
        return 0;
    }
    int count = 0, max = getdtablesize();
    for (int fd = 0; fd < max; fd++) {
        char open[PATH_MAX];
        if (fcntl(fd, F_GETPATH, open) == 0 && strcmp(open, resolved) == 0) {
            count++;
        }
    }
    return count;
}

- (AudioFileHandle *)open:(NSURL *)url {
    NSError *error = nil;
    AudioFileHandle *handle = [[AudioFileHandle alloc] initForReading:url error:&error];
    XCTAssertNotNil(handle, @"%@: %@", url.lastPathComponent, error);
    return handle;
}

#pragma mark - Verdicts

- (void)testLegacyWavPackInRIFFIsRefused {
    for (uint8_t version = 1; version <= 3; version++) {
        const uint8_t header[] = {'w', 'v', 'p', 'k', 28, 0, 0, 0, version, 0};
        NSMutableData *payload = [NSMutableData dataWithBytes:header length:sizeof header];
        [payload increaseLengthBy:54];
        NSString *name = [NSString stringWithFormat:@"legacy-%u.%@", (unsigned)version, version == 3 ? @"wav" : @"wv"];
        NSURL *url = VibeWriteWAV([self.fixtureDirectory URLByAppendingPathComponent:name], payload, 44100, 2, 16, 64);
        XCTAssertNotNil(url);
        NSError *error = nil;
        XCTAssertNil([[AudioFileHandle alloc] initForReading:url error:&error]);
        XCTAssertEqualObjects(error.domain, NSOSStatusErrorDomain);
        XCTAssertEqual(error.code, kAudioFileUnsupportedDataFormatError);
    }
}

- (void)testMissingPathIsRefusedWithAPOSIXError {
    NSURL *url = [self.fixtureDirectory URLByAppendingPathComponent:@"missing.wav"];
    NSError *error = nil;
    XCTAssertNil([[AudioFileHandle alloc] initForReading:url error:&error]);
    XCTAssertEqualObjects(error.domain, NSPOSIXErrorDomain);
    XCTAssertFalse(url.isEmptyOrDirectory, @"unstattable is not empty: the open reports why");
}

- (void)testEmptyFileIsRefused {
    NSURL *url = [self.fixtureDirectory URLByAppendingPathComponent:@"empty.wav"];
    XCTAssertTrue([NSData.data writeToURL:url atomically:YES]);
    NSError *error = nil;
    XCTAssertNil([[AudioFileHandle alloc] initForReading:url error:&error]);
    XCTAssertEqualObjects(error.domain, NSOSStatusErrorDomain);
    XCTAssertTrue(url.isEmptyOrDirectory);
}

- (void)testDirectoryIsRefused {
    NSURL *url = [self.fixtureDirectory URLByAppendingPathComponent:@"folder" isDirectory:YES];
    NSError *error = nil;
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:url
                                          withIntermediateDirectories:NO
                                                           attributes:nil
                                                                error:&error], @"%@", error);
    XCTAssertNil([[AudioFileHandle alloc] initForReading:url error:&error]);
    XCTAssertTrue(url.isEmptyOrDirectory);
}

// A FIFO with no writer blocks a plain open forever; the handle must refuse
// it at once, or a queued open worker is stranded until a writer appears.
- (void)testAWriterlessFIFOIsRefusedWithoutBlocking {
    NSURL *url = [self.fixtureDirectory URLByAppendingPathComponent:@"pipe.wav"];
    XCTAssertEqual(mkfifo(url.fileSystemRepresentation, 0600), 0, @"mkfifo: %s", strerror(errno));
    XCTestExpectation *returned = [self expectationWithDescription:@"open returned"];
    __block NSError *error = nil;
    __block AudioFileHandle *handle = nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        handle = [[AudioFileHandle alloc] initForReading:url error:&error];
        [returned fulfill];
    });
    [self waitForExpectations:@[returned] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertNil(handle);
    XCTAssertEqualObjects(error.domain, NSOSStatusErrorDomain);
}

- (void)testInvalidAudioIsRefused {
    NSURL *url = [self.fixtureDirectory URLByAppendingPathComponent:@"invalid.wav"];
    XCTAssertTrue([[@"not audio" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:url atomically:YES]);
    NSError *error = nil;
    XCTAssertNil([[AudioFileHandle alloc] initForReading:url error:&error]);
    XCTAssertEqualObjects(error.domain, NSOSStatusErrorDomain);
}

- (void)testNonAudioNamedAsMP3IsRefused {
    NSURL *url = [self.fixtureDirectory URLByAppendingPathComponent:@"invalid.mp3"];
    XCTAssertTrue([[@"not audio" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:url atomically:YES]);
    XCTAssertNil([[AudioFileHandle alloc] initForReading:url error:NULL]);
}

// An ID3v2 tag of `size` zero bytes, with a footer when `flags` say so, then
// `next`: the start of a second tag.
static NSData *VibeID3TagWithFlagsThen(uint8_t version, uint8_t flags, NSUInteger size, NSData *next) {
    const uint8_t header[10] = {'I', 'D', '3', version, 0, flags, 0, 0, (uint8_t)(size >> 7 & 0x7F), (uint8_t)(size & 0x7F)};
    NSMutableData *bytes = [NSMutableData dataWithBytes:header length:sizeof header];
    [bytes increaseLengthBy:size + (flags & 0x10 ? 10 : 0)];
    [bytes appendData:next];
    return bytes;
}

static NSData *VibeID3TagThen(NSUInteger size, NSData *next) {
    return VibeID3TagWithFlagsThen(4, 0, size, next);
}

// CoreAudio's MPEG reader never returns on a second tag whose header is cut
// short or has a version of 0xFF, whatever the extension (AudioFileHandle.m).
- (void)testAnID3TagThatWouldHangCoreAudioIsRefused {
    NSData *cut = [NSData dataWithBytes:"ID3" length:3];
    NSData *versionFF = [NSData dataWithBytes:"ID3\xFF\x00\x00\x00\x00\x00\x10" length:10];
    NSData *revisionFF = [NSData dataWithBytes:"ID3\x04\xFF\x00\x00\x00\x00\x10" length:10];
    // CoreAudio counts a footer in v2.3 too, though there 0x10 is the experimental bit.
    NSDictionary<NSString *, NSData *> *files = @{
        @"cut.mp3": VibeID3TagThen(474, cut),
        @"cut.wav": VibeID3TagThen(474, cut),
        @"version.mp3": VibeID3TagThen(100, versionFF),
        @"revision.mp3": VibeID3TagThen(100, revisionFF),
        @"footer-v24.mp3": VibeID3TagWithFlagsThen(4, 0x10, 100, cut),
        @"footer-v23.mp3": VibeID3TagWithFlagsThen(3, 0x10, 100, cut),
    };
    for (NSString *name in files) {
        NSURL *url = [self.fixtureDirectory URLByAppendingPathComponent:name];
        XCTAssertTrue([files[name] writeToURL:url atomically:YES]);
        XCTestExpectation *returned = [self expectationWithDescription:name];
        __block AudioFileHandle *handle = nil;
        __block NSError *error = nil;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            handle = [[AudioFileHandle alloc] initParserForReading:url error:&error];
            [returned fulfill];
        });
        [self waitForExpectations:@[returned] timeout:VIBE_TEST_HANG_TIMEOUT];
        XCTAssertNil(handle, @"%@", name);
        XCTAssertEqualObjects(error.domain, NSOSStatusErrorDomain, @"%@", name);
    }
}

- (void)testAnMP3WithTwoID3TagsStillOpensInCoreAudio {
    NSURL *url = [self.fixtureDirectory URLByAppendingPathComponent:@"two-tags.mp3"];
    XCTAssertTrue([VibeID3TagThen(16, VibeTaggedMP3WithGap(0)) writeToURL:url atomically:YES]);
    NSError *error = nil;
    AudioFileHandle *handle = [[AudioFileHandle alloc] initParserForReading:url error:&error];
    XCTAssertNotNil(handle, @"%@", error);
    AudioStreamBasicDescription format = {0};
    UInt32 size = sizeof format;
    XCTAssertEqual(AudioFileGetProperty(handle.parser, kAudioFilePropertyDataFormat, &size, &format), noErr);
    XCTAssertEqual(format.mFormatID, kAudioFormatMPEGLayer3);
}

// CoreAudio's own open plays this file but sniffing alone refuses it, so the
// hinted parse comes first.
- (void)testMP3WithUndeclaredBytesAfterItsTagIsAccepted {
    NSURL *url = [self.fixtureDirectory URLByAppendingPathComponent:@"gap.mp3"];
    XCTAssertTrue([VibeTaggedMP3WithGap(1000) writeToURL:url atomically:YES]);
    AudioFileHandle *handle = [self open:url];
    XCTAssertEqual(handle.fileFormat.streamDescription->mFormatID, kAudioFormatMPEGLayer3);
    XCTAssertEqual(handle.length, (AVAudioFramePosition)40 * 1152);
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:handle.processingFormat
                                                             frameCapacity:(AVAudioFrameCount)handle.length + 1024];
    NSError *error = nil;
    XCTAssertTrue([handle readIntoBuffer:buffer error:&error], @"%@", error);
    XCTAssertEqual(buffer.frameLength, (AVAudioFrameCount)handle.length, @"the read runs to the declared end");
}

// `bytes` with zeros over `frames` 1,044-byte frames from frame `first`,
// starting 500 bytes into the frame before them: the hole a download leaves
// where a block never arrived.
static NSData *VibeMP3WithHole(NSData *bytes, NSUInteger first, NSUInteger frames) {
    NSMutableData *holed = [bytes mutableCopy];
    [holed resetBytesInRange:NSMakeRange(first * 1044 - 544, frames * 1044)];
    return holed;
}

- (AVAudioFramePosition)framesReadToTheEndOf:(AudioFileHandle *)handle {
    AVAudioFramePosition start = handle.framePosition;
    NSError *error = nil;
    XCTAssertTrue(VibeReadToEnd(handle, [NSMutableData data], &error), @"%@", error);
    return handle.framePosition - start;
}

// A hole longer than the walk's span once ended the stream: a song with one
// played to the hole and stopped, under a length that counted every frame.
- (void)testAnMP3WithAHoleOfZerosPlaysThroughItAsSilence {
    NSData *whole = VibeMP3WithInfoFrame(1000, YES);
    NSURL *url = [self.fixtureDirectory URLByAppendingPathComponent:@"hole.mp3"];
    // 200 frames, 208,800 bytes, from the 100th frame after the Info frame.
    XCTAssertTrue([VibeMP3WithHole(whole, 101, 200) writeToURL:url atomically:YES]);
    AudioFileHandle *handle = [self open:url];
    XCTAssertEqual(handle.length, (AVAudioFramePosition)1000 * 1152, @"the Info frame's count stands");
    XCTAssertEqual([self framesReadToTheEndOf:handle], handle.length, @"the reads cross the hole");

    // A seek into the hole, and one past it, read on to the end.
    for (NSNumber *packet in @[@150, @400]) {
        AVAudioFramePosition target = packet.longLongValue * 1152 + 7;
        NSError *error = nil;
        XCTAssertTrue([handle seekToFrame:target error:&error], @"%@", error);
        XCTAssertEqual([self framesReadToTheEndOf:handle], handle.length - target, @"from packet %@", packet);
    }
}

// With no count stated, the walk counts the packets damage took itself, so
// the frames after it keep their place in the song, whether the damage is a
// long hole or ten frames. Once, damage within the walk's span was passed
// over, and the stream ended that much short of a stated length.
- (void)testAnUncountedMP3CountsThePacketsDamageTook {
    [self assertUncountedMP3Named:@"hole.mp3" withZerosOverFrames:200 holdsPackets:1000];
    [self assertUncountedMP3Named:@"damage.mp3" withZerosOverFrames:10 holdsPackets:1000];
    [self assertUncountedMP3Named:@"one-frame.mp3" withZerosOverFrames:1 holdsPackets:1000];
}

- (void)assertUncountedMP3Named:(NSString *)name withZerosOverFrames:(NSUInteger)frames holdsPackets:(SInt64)packets {
    NSData *whole = VibeMP3WithoutVBRHeader(1000, 44100, ^uint8_t(uint32_t frame) { return 14; });
    NSURL *url = [self.fixtureDirectory URLByAppendingPathComponent:name];
    XCTAssertTrue([VibeMP3WithHole(whole, 100, frames) writeToURL:url atomically:YES]);
    AudioFileHandle *handle = [self open:url];
    XCTAssertEqual(handle.length, (AVAudioFramePosition)packets * 1152, @"%@", name);
    XCTAssertEqual([self framesReadToTheEndOf:handle], handle.length, @"%@", name);
}

// Bytes between frames that held no audio add no silence: a tag, as two
// files joined keep the second's, and stray bytes short of half a frame.
- (void)testATagOrStrayBytesBetweenFramesAddNoSilence {
    NSData *half = VibeMP3WithoutVBRHeader(100, 44100, ^uint8_t(uint32_t frame) { return 14; });
    NSDictionary<NSString *, NSData *> *between = @{
        @"tag.mp3": VibeID3v2Tag(3, 0, [NSMutableData dataWithLength:5000]),
        @"stray.mp3": [NSMutableData dataWithLength:400],
    };
    for (NSString *name in between) {
        NSMutableData *bytes = [half mutableCopy];
        [bytes appendData:between[name]];
        [bytes appendData:half];
        NSURL *url = [self.fixtureDirectory URLByAppendingPathComponent:name];
        XCTAssertTrue([bytes writeToURL:url atomically:YES]);
        AudioFileHandle *handle = [self open:url];
        XCTAssertEqual(handle.length, (AVAudioFramePosition)200 * 1152, @"%@", name);
        XCTAssertEqual([self framesReadToTheEndOf:handle], handle.length, @"%@", name);
    }
}

// Zeros that run to the file's end hold no frame to take up at, so the
// stream ends where they begin, as a file cut short does.
- (void)testAnMP3ThatEndsInZerosEndsWhereTheyBegin {
    NSMutableData *bytes = [VibeMP3WithoutVBRHeader(100, 44100, ^uint8_t(uint32_t frame) { return 14; }) mutableCopy];
    [bytes increaseLengthBy:300 * 1024];
    NSURL *url = [self.fixtureDirectory URLByAppendingPathComponent:@"zeros-after.mp3"];
    XCTAssertTrue([bytes writeToURL:url atomically:YES]);
    AudioFileHandle *handle = [self open:url];
    XCTAssertEqual(handle.length, (AVAudioFramePosition)100 * 1152);
    XCTAssertEqual([self framesReadToTheEndOf:handle], handle.length);
}

- (void)testMislabeledFileOpensByContent {
    NSURL *url = [self writePCMNamed:@"actually-a-wav.mp3" frames:2048 channels:2 rate:48000];
    AudioFileHandle *handle = [self open:url];
    XCTAssertEqual(handle.fileFormat.streamDescription->mFormatID, kAudioFormatLinearPCM);
    XCTAssertEqual(handle.length, (AVAudioFramePosition)2048);
}

- (void)testValidContainerWithNoAudioIsOpenedWithZeroLength {
    NSURL *url = [self writePCMNamed:@"zero-frames.wav" frames:0 channels:1 rate:44100];
    AudioFileHandle *handle = [self open:url];
    XCTAssertEqualObjects(handle.decoderName, @"dr_wav");
    XCTAssertEqual(handle.length, (AVAudioFramePosition)0);
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:handle.processingFormat frameCapacity:64];
    XCTAssertTrue([handle readIntoBuffer:buffer error:NULL]);
    XCTAssertEqual(buffer.frameLength, 0u);
}

// The shape of a partial download; CoreAudio's own reader reports the same.
- (void)testAnOverdeclaredWAVReportsTheFramesItHolds {
    NSMutableData *samples = [NSMutableData dataWithLength:3000 * 4];
    NSURL *url = VibeWriteWAV([self.fixtureDirectory URLByAppendingPathComponent:@"overdeclared.wav"], samples, 48000, 2, 16, 20000 * 4);
    AudioFileHandle *handle = [self open:url];
    XCTAssertEqual(handle.length, (AVAudioFramePosition)3000);
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:handle.processingFormat frameCapacity:8192];
    XCTAssertTrue([handle readIntoBuffer:buffer error:NULL]);
    XCTAssertEqual(buffer.frameLength, 3000u);
}

// The packet count CoreAudio derives answers 0 for a WAV of one or two
// frames; the byte count is the length.
- (void)testATwoFrameWAVHasLengthTwo {
    AudioFileHandle *handle = [self open:[self writePCMNamed:@"two.wav" frames:2 channels:2 rate:44100]];
    XCTAssertEqual(handle.length, (AVAudioFramePosition)2);
}

#pragma mark - Facts and reads

- (void)testFactsAndAFullReadOfAWrittenFile {
    NSURL *url = [self writePCMNamed:@"valid.wav" frames:5000 channels:2 rate:44100];
    AudioFileHandle *handle = [self open:url];
    XCTAssertEqualObjects(handle.url, url);
    XCTAssertEqual(handle.fileFormat.sampleRate, 44100.0);
    XCTAssertEqual(handle.fileFormat.channelCount, 2u);
    XCTAssertEqual(handle.fileFormat.streamDescription->mBitsPerChannel, 16u);
    XCTAssertEqual(handle.processingFormat.commonFormat, AVAudioPCMFormatFloat32);
    XCTAssertFalse(handle.processingFormat.isInterleaved);
    XCTAssertEqual(handle.processingFormat.sampleRate, 44100.0);
    XCTAssertEqual(handle.length, (AVAudioFramePosition)5000);
    XCTAssertEqual(handle.framePosition, (AVAudioFramePosition)0);

    // A read larger than the file comes up short, exactly at the end, and the
    // next read at the end is empty and not an error.
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:handle.processingFormat frameCapacity:8192];
    NSError *error = nil;
    XCTAssertTrue([handle readIntoBuffer:buffer frameCount:8192 error:&error], @"%@", error);
    XCTAssertEqual(buffer.frameLength, 5000u);
    XCTAssertEqual(handle.framePosition, (AVAudioFramePosition)5000);
    for (uint32_t frame = 0; frame < 5000; frame++) {
        for (uint32_t channel = 0; channel < 2; channel++) {
            float expected = VibeFixtureSample(frame, channel) / 32768.0f;
            if (buffer.floatChannelData[channel][frame] != expected) {
                XCTFail(@"frame %u channel %u: %g, expected %g", frame, channel, buffer.floatChannelData[channel][frame], expected);
                return;
            }
        }
    }
    XCTAssertTrue([handle readIntoBuffer:buffer frameCount:1024 error:&error], @"%@", error);
    XCTAssertEqual(buffer.frameLength, 0u);
}

- (void)testInterleavedProcessingFormatReadsFramesInOrder {
    NSURL *url = [self writePCMNamed:@"interleaved.wav" frames:300 channels:2 rate:48000];
    NSError *error = nil;
    AudioFileHandle *handle = [[AudioFileHandle alloc] initForReading:url interleaved:YES error:&error];
    XCTAssertNotNil(handle, @"%@", error);
    XCTAssertTrue(handle.processingFormat.isInterleaved);
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:handle.processingFormat frameCapacity:300];
    XCTAssertTrue([handle readIntoBuffer:buffer error:&error], @"%@", error);
    XCTAssertEqual(buffer.frameLength, 300u);
    for (uint32_t frame = 0; frame < 300; frame++) {
        XCTAssertEqual(buffer.floatChannelData[0][frame * 2], VibeFixtureSample(frame, 0) / 32768.0f);
        XCTAssertEqual(buffer.floatChannelData[0][frame * 2 + 1], VibeFixtureSample(frame, 1) / 32768.0f);
    }
}

- (void)testABufferOfAnotherFormatIsRefused {
    AudioFileHandle *handle = [self open:[self writePCMNamed:@"format.wav" frames:100 channels:2 rate:44100]];
    AVAudioFormat *other = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100 channels:1];
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:other frameCapacity:64];
    NSError *error = nil;
    XCTAssertFalse([handle readIntoBuffer:buffer error:&error]);
    XCTAssertNotNil(error);
    XCTAssertEqual(buffer.frameLength, 0u);
}

- (void)testTheCursorSeeksInFileFrames {
    AudioFileHandle *handle = [self open:[self writePCMNamed:@"seek.wav" frames:4000 channels:1 rate:44100]];
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:handle.processingFormat frameCapacity:16];
    XCTAssertTrue([handle seekToFrame:1234 error:NULL]);
    XCTAssertEqual(handle.framePosition, (AVAudioFramePosition)1234);
    XCTAssertTrue([handle readIntoBuffer:buffer error:NULL]);
    XCTAssertEqual(buffer.frameLength, 16u);
    XCTAssertEqual(buffer.floatChannelData[0][0], VibeFixtureSample(1234, 0) / 32768.0f);
    XCTAssertEqual(handle.framePosition, (AVAudioFramePosition)1250);

    XCTAssertTrue([handle seekToFrame:3995 error:NULL]);
    XCTAssertTrue([handle readIntoBuffer:buffer error:NULL]);
    XCTAssertEqual(buffer.frameLength, 5u, @"a read across the end stops at it");
    XCTAssertEqual(buffer.floatChannelData[0][4], VibeFixtureSample(3999, 0) / 32768.0f);

    XCTAssertTrue([handle seekToFrame:9000 error:NULL]);
    XCTAssertTrue([handle readIntoBuffer:buffer error:NULL]);
    XCTAssertEqual(buffer.frameLength, 0u, @"past the end reads nothing");

    XCTAssertTrue([handle seekToFrame:-5 error:NULL]);
    XCTAssertEqual(handle.framePosition, (AVAudioFramePosition)0);
}

// A converter between more than two channels needs a layout, and the bus's
// mix map reads it.
- (void)testAWiderFileWithoutALayoutDecodesDiscreteChannels {
    AudioFileHandle *handle = [self open:[self writePCMNamed:@"quad.wav" frames:512 channels:4 rate:48000]];
    XCTAssertEqual(handle.processingFormat.channelCount, 4u);
    XCTAssertEqual(handle.processingFormat.channelLayout.layoutTag, kAudioChannelLayoutTag_DiscreteInOrder | 4);
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:handle.processingFormat frameCapacity:512];
    NSError *error = nil;
    XCTAssertTrue([handle readIntoBuffer:buffer error:&error], @"%@", error);
    XCTAssertEqual(buffer.frameLength, 512u);
    for (uint32_t channel = 0; channel < 4; channel++) {
        XCTAssertEqual(buffer.floatChannelData[channel][511], VibeFixtureSample(511, channel) / 32768.0f, @"channel %u", channel);
    }
}

#pragma mark - Ownership

// A descriptor leaked per refused open turns a library of partial downloads
// into an exhausted process.
- (void)testOpensAndRefusalsLeaveNoDescriptorBehind {
    NSURL *valid = [self writePCMNamed:@"owned.wav" frames:1024 channels:2 rate:44100];
    NSURL *invalid = [self.fixtureDirectory URLByAppendingPathComponent:@"refused.wav"];
    XCTAssertTrue([[@"still not audio" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:invalid atomically:YES]);
    NSURL *empty = [self.fixtureDirectory URLByAppendingPathComponent:@"refused-empty.wav"];
    XCTAssertTrue([NSData.data writeToURL:empty atomically:YES]);
    // Warm CoreAudio's own caches so the baseline is the steady state.
    @autoreleasepool {
        (void)[[AudioFileHandle alloc] initForReading:valid error:NULL];
        (void)[[AudioFileHandle alloc] initForReading:invalid error:NULL];
    }
    int baseline = VibeOpenDescriptorCount();
    for (int i = 0; i < 40; i++) {
        @autoreleasepool {
            (void)[[AudioFileHandle alloc] initForReading:invalid error:NULL];
            (void)[[AudioFileHandle alloc] initForReading:empty error:NULL];
            (void)[[AudioFileHandle alloc] initParserForReading:invalid error:NULL];
            XCTAssertTrue([[AudioFileHandle alloc] initParserForReading:valid error:NULL].parser != NULL);
            AudioFileHandle *handle = [[AudioFileHandle alloc] initForReading:valid error:NULL];
            AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:handle.processingFormat frameCapacity:2048];
            (void)[handle readIntoBuffer:buffer error:NULL];
        }
    }
    XCTAssertEqual(VibeOpenDescriptorCount(), baseline);
}

// A close can wait on a share's server, and the player lets handles go where
// main waits. An interruptible open's release leaves the close to its queue.
- (void)testAnInterruptibleOpenClosesItsFileOnTheCloseQueue {
    NSURL *url = [self writePCMNamed:@"deferred.wav" frames:1024 channels:2 rate:44100];
    dispatch_queue_t closes = AudioFileHandle.debugCloseQueue;
    dispatch_suspend(closes);
    @autoreleasepool {
        XCTAssertNotNil([[AudioFileHandle alloc] initForReading:url interleaved:NO
                                                    interrupted:^BOOL { return NO; } error:NULL]);
    }
    XCTAssertEqual(VibeDescriptorsOpenOn(url), 1, @"released, and still open");
    dispatch_resume(closes);
    dispatch_sync(closes, ^{});
    XCTAssertEqual(VibeDescriptorsOpenOn(url), 0);
}

- (void)testAHandleOutlivesTheScopeThatOpenedIt {
    NSURL *url = [self writePCMNamed:@"kept.wav" frames:256 channels:1 rate:44100];
    AudioFileHandle *kept = nil;
    @autoreleasepool {
        kept = [self open:url];
    }
    XCTAssertTrue([NSFileManager.defaultManager removeItemAtURL:url error:NULL], @"the open file can be unlinked");
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:kept.processingFormat frameCapacity:256];
    XCTAssertTrue([kept readIntoBuffer:buffer error:NULL], @"the descriptor, not the path, is what is read");
    XCTAssertEqual(buffer.frameLength, 256u);
}

// dr_wav is offered only the containers it reads, so no other open pays its
// read and failed parse; within them it keeps the codings it decodes.
- (void)testDrWAVIsTriedOnlyOnItsOwnContainers {
    AVAudioFormat *processing = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100 channels:2];
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:processing frameCapacity:4096];
    buffer.frameLength = 4096;
    for (AVAudioFrameCount f = 0; f < buffer.frameLength; f++) {
        buffer.floatChannelData[0][f] = VibeFixtureSample(f, 0) / 32768.0f;
        buffer.floatChannelData[1][f] = VibeFixtureSample(f, 1) / 32768.0f;
    }
    NSDictionary<NSString *, NSString *> *decoders = @{
        @"float.wav": @"dr_wav", @"float.w64": @"dr_wav", @"float.aif": @"dr_wav", @"float.caf": @"apple"};
    for (NSString *name in decoders) {
        NSError *error = nil;
        NSURL *url = VibeWriteFixture([self.fixtureDirectory URLByAppendingPathComponent:name], buffer, &error);
        XCTAssertNotNil(url, @"%@: %@", name, error);
        AudioFileHandle *reader = [self open:url];
        XCTAssertEqualObjects(reader.decoderName, decoders[name], @"%@", name);
        XCTAssertEqual(reader.length, 4096, @"%@", name);
    }
    NSMutableData *samples = [NSMutableData dataWithLength:4096 * 2 * 3];
    NSURL *sowt = VibeWriteSowtAIFF([self.fixtureDirectory URLByAppendingPathComponent:@"sowt.aif"], samples, 44100, 2, 24);
    XCTAssertEqualObjects([self open:sowt].decoderName, @"dr_wav", @"a sowt AIFF-C, which only dr_wav reads right");
}

- (void)testIMA4CountsWholePacketsExceptInBlockAlignedSoundData {
    // COMM claims one stereo packet. SSND holds three and, in the unaligned
    // file, the first eight bytes of a fourth packet before it is cut short.
    const char header[] =
        "FORM\0\0\0\0AIFCFVER\0\0\0\4\xA2\x80\x51\x40"
        "COMM\0\0\0\x18\0\2\0\0\0\1\0\x10\x40\x0e\xac\x44\0\0\0\0\0\0ima4\0\0"
        "SSND\0\0\0\0\0\0\0\0\0\0\0\0";
    enum { packetBytes = 68, packetFrames = 64, packets = 3, headerBytes = sizeof header - 1 };
    for (NSNumber *aligned in @[@NO, @YES]) {
        uint32_t blockSize = aligned.boolValue ? packets * packetBytes : 0;
        uint32_t offset = blockSize ? blockSize - headerBytes : 0;
        NSMutableData *aiff = [NSMutableData dataWithBytes:header length:headerBytes];
        [aiff increaseLengthBy:offset + packets * packetBytes + (blockSize ? 0 : 8)];
        uint32_t formSize = CFSwapInt32HostToBig(headerBytes - 8 + offset + (blockSize ? packets : packets + 1) * packetBytes);
        uint32_t sound[] = {CFSwapInt32HostToBig(8 + offset + (blockSize ? packets : packets + 1) * packetBytes),
                            CFSwapInt32HostToBig(offset), CFSwapInt32HostToBig(blockSize)};
        [aiff replaceBytesInRange:NSMakeRange(4, 4) withBytes:&formSize];
        [aiff replaceBytesInRange:NSMakeRange(headerBytes - sizeof sound, sizeof sound) withBytes:sound];
        NSURL *url = [self.fixtureDirectory URLByAppendingPathComponent:blockSize ? @"aligned.aifc" : @"truncated.aifc"];
        XCTAssertTrue([aiff writeToURL:url atomically:YES]);
        AudioFileHandle *reader = [self open:url];
        XCTAssertEqualObjects(reader.decoderName, @"dr_wav");
        XCTAssertEqual(reader.fileFormat.streamDescription->mFormatID, kAudioFormatAppleIMA4);
        AVAudioFramePosition expected = (blockSize ? 1 : packets) * packetFrames;
        XCTAssertEqual(reader.length, expected);
        XCTAssertTrue([reader seekToFrame:expected - 1 error:NULL]);
        AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:reader.processingFormat frameCapacity:2];
        XCTAssertTrue([reader readIntoBuffer:buffer error:NULL]);
        XCTAssertEqual(buffer.frameLength, 1u);
    }
}

// A QuickTime container (.qta, what Voice Memos exports) has no callback open
// in CoreAudio, so the handle opens it by URL. AVAudioFile cannot write one,
// hence the asset writer.
- (void)testQuickTimeContainerOpensThroughItsOwnReader {
    NSURL *url = [self.fixtureDirectory URLByAppendingPathComponent:@"memo.qta"];
    NSError *error = nil;
    AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:url
                                                     fileType:AVFileTypeQuickTimeMovie
                                                        error:&error];
    XCTAssertNotNil(writer, @"%@", error);
    AVAssetWriterInput *input = [AVAssetWriterInput
            assetWriterInputWithMediaType:AVMediaTypeAudio
                           outputSettings:@{AVFormatIDKey: @(kAudioFormatMPEG4AAC),
                                            AVSampleRateKey: @44100,
                                            AVNumberOfChannelsKey: @1}];
    [writer addInput:input];
    XCTAssertTrue([writer startWriting], @"%@", writer.error);
    [writer startSessionAtSourceTime:kCMTimeZero];

    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100
                                                                          channels:1];
    AVAudioPCMBuffer *silence = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format
                                                              frameCapacity:4096];
    silence.frameLength = 4096;
    memset(silence.floatChannelData[0], 0, sizeof(float) * silence.frameLength);
    CMFormatDescriptionRef description = NULL;
    XCTAssertEqual(CMAudioFormatDescriptionCreate(kCFAllocatorDefault, format.streamDescription,
                                                  0, NULL, 0, NULL, NULL, &description), noErr);
    CMSampleBufferRef sample = NULL;
    XCTAssertEqual(CMAudioSampleBufferCreateWithPacketDescriptions(
                           kCFAllocatorDefault, NULL, false, NULL, NULL, description,
                           silence.frameLength, kCMTimeZero, NULL, &sample), noErr);
    XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(
                           sample, kCFAllocatorDefault, kCFAllocatorDefault, 0,
                           silence.audioBufferList), noErr);
    while (!input.readyForMoreMediaData) {
        [NSThread sleepForTimeInterval:0.001];
    }
    XCTAssertTrue([input appendSampleBuffer:sample], @"%@", writer.error);
    CFRelease(sample);
    CFRelease(description);
    [input markAsFinished];
    XCTestExpectation *finished = [self expectationWithDescription:@"finishWriting"];
    [writer finishWritingWithCompletionHandler:^{ [finished fulfill]; }];
    [self waitForExpectations:@[finished] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqual(writer.status, AVAssetWriterStatusCompleted, @"%@", writer.error);

    AudioFileHandle *handle = [self open:url];
    XCTAssertEqual(handle.fileFormat.streamDescription->mFormatID, kAudioFormatMPEG4AAC);
    XCTAssertGreaterThan(handle.length, 0);
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:handle.processingFormat
                                                             frameCapacity:(AVAudioFrameCount)handle.length + 1024];
    XCTAssertTrue([handle readIntoBuffer:buffer error:&error], @"%@", error);
    XCTAssertEqual(buffer.frameLength, (AVAudioFrameCount)handle.length);
    handle = nil;
    // The QuickTime reader keeps two descriptors of its own from its first
    // load in a process; what must not grow is the count per open.
    int baseline = VibeOpenDescriptorCount();
    for (int i = 0; i < 10; i++) {
        @autoreleasepool {
            (void)[[AudioFileHandle alloc] initForReading:url error:NULL];
        }
    }
    XCTAssertEqual(VibeOpenDescriptorCount(), baseline, @"the container's own reader returns its descriptor");
}

// Apple's MPEG decoders output Int16 only on arm64, so an MP3 or MP2 decode is
// already on the 16-bit grid and any integer depth or float carries it exactly;
// their x86_64 build also outputs float32, as the AAC decoder does on both,
// which 16 bits would round. docs/audio-quality.md's findings for Apple's MPEG
// decoder rest on this.
- (void)testAppleMPEGDecodersOutputInt16OnlyOnArm64AndAACOutputsFloat {
#if defined(__arm64__)
    NSNumber *mpegFloat = @NO;
#else
    NSNumber *mpegFloat = @YES;
#endif
    NSDictionary<NSNumber *, NSNumber *> *floatOffered = @{
        @(kAudioFormatMPEGLayer3): mpegFloat, @(kAudioFormatMPEGLayer2): mpegFloat, @(kAudioFormatMPEG4AAC): @YES,
    };
    for (NSNumber *format in floatOffered) {
        AudioComponentDescription description = { kAudioDecoderComponentType, format.unsignedIntValue, kAudioUnitManufacturer_Apple, 0, 0 };
        AudioComponent component = AudioComponentFindNext(NULL, &description);
        XCTAssertTrue(component != NULL, @"no Apple decoder for %@", format);
        AudioCodec codec = NULL;
        XCTAssertEqual(AudioComponentInstanceNew(component, &codec), noErr);
        UInt32 size = 0;
        Boolean writable = false;
        XCTAssertEqual(AudioCodecGetPropertyInfo(codec, kAudioCodecPropertySupportedOutputFormats, &size, &writable), noErr);
        NSMutableData *list = [NSMutableData dataWithLength:size];
        XCTAssertEqual(AudioCodecGetProperty(codec, kAudioCodecPropertySupportedOutputFormats, &size, list.mutableBytes), noErr);
        const AudioStreamBasicDescription *outputs = list.bytes;
        BOOL anyFloat = NO, anyInt16 = NO;
        for (NSUInteger i = 0; i < size / sizeof(AudioStreamBasicDescription); i++) {
            anyFloat |= (outputs[i].mFormatFlags & kAudioFormatFlagIsFloat) != 0;
            anyInt16 |= !(outputs[i].mFormatFlags & kAudioFormatFlagIsFloat) && outputs[i].mBitsPerChannel == 16;
        }
        XCTAssertEqual(anyFloat, floatOffered[format].boolValue, @"decoder %@ float output", format);
        XCTAssertTrue(anyInt16, @"decoder %@ Int16 output", format);
        AudioComponentInstanceDispose(codec);
    }
}

@end
