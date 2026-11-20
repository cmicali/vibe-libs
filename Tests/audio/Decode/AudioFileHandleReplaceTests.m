//
//  AudioFileHandleReplaceTests.m
//  vibe-libs
//
//  The probe behind a tag editor's safe write: a copy of the file is
//  rewritten and swapped in while a player reads the original. What it
//  shows, for each of the handle's opens (dr_wav for WAV and AIFF, dr_flac,
//  dr_mp3, libvorbis, and CoreAudio's parser for AAC and Opus): a handle
//  that has read the original's first 4,096 frames reads the rest of the
//  original's samples, identical to a fresh decode of a saved copy, with no
//  error, after rename(2) moves a copy over its path, and after
//  renamex_np's RENAME_SWAP trades the two. Each original is megabytes long,
//  so the reads after the swap are many. The copy is about a quarter as long. The
//  PCM and AAC copies are silent where the original sounds. Both MP3s are
//  silent, and the copy's frames differ in rate and channels. The Ogg
//  copies repeat the same pages fewer times. The path is checked to hold
//  the copy. A local file is read through its descriptor, with no
//  read-ahead, so this shows the descriptor follows the original's inode.
//  It shows nothing about a network share, nor about a file a reader
//  reopens by path.
//

#import <XCTest/XCTest.h>
#import <AVFoundation/AVFoundation.h>
#include <float.h>
#include <stdio.h>

#import "AudioFileHandle.h"
#import "AudioFileFixtures.h"
#import "OggFixtures.h"

@interface AudioFileHandleReplaceTests : XCTestCase
@end

@implementation AudioFileHandleReplaceTests {
    NSURL *_dir;
}

- (void)setUp {
    [super setUp];
    _dir = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]
                      isDirectory:YES];
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:_dir withIntermediateDirectories:YES
                                                          attributes:nil error:NULL]);
}

- (void)tearDown {
    [NSFileManager.defaultManager removeItemAtURL:_dir error:NULL];
    [super tearDown];
}

static NSData *VibeSeed(NSString *name) {
    NSString *here = [@__FILE__ stringByDeletingLastPathComponent];
    return [NSData dataWithContentsOfFile:[here stringByAppendingPathComponent:
            [@"../../Fuzz/Seeds/tags-ogg" stringByAppendingPathComponent:name]]];
}

// MPEG-1 Layer III frames of silence at 320 kbps: 44.1 kHz stereo for the
// original, 48 kHz mono for the copy, so the copy's bytes and stream differ.
static NSData *VibeMP3Frames(NSUInteger frames, BOOL original) {
    const NSUInteger size = original ? 1044 : 960;
    NSMutableData *bytes = [NSMutableData dataWithLength:frames * size];
    for (NSUInteger frame = 0; frame < frames; frame++) {
        memcpy((uint8_t *)bytes.mutableBytes + frame * size, original ? "\xFF\xFB\xE0\x00" : "\xFF\xFB\xE4\xC0", 4);
    }
    return bytes;
}

// The original, 90 seconds of the tone, or the copy that replaces it:
// about a quarter as long, and silent where the format allows.
- (NSURL *)write:(NSString *)name original:(BOOL)original {
    NSURL *url = [_dir URLByAppendingPathComponent:name];
    NSString *extension = name.pathExtension;
    NSError *error = nil;
    if ([extension isEqualToString:@"mp3"]) {
        XCTAssertTrue([VibeMP3Frames(original ? 3450 : 860, original) writeToURL:url atomically:NO]);
        return url;
    }
    if ([extension isEqualToString:@"ogg"] || [extension isEqualToString:@"opus"]) {
        NSData *seed = VibeSeed([extension isEqualToString:@"ogg"] ? @"vorbis.ogg" : @"opus.ogg");
        XCTAssertNotNil(seed);
        const NSUInteger repeats = [extension isEqualToString:@"ogg"] ? 1600 : 16000;
        XCTAssertTrue([VibeRepeatedOgg(seed, original ? repeats : repeats / 4) writeToURL:url atomically:NO]);
        return url;
    }
    const AVAudioFrameCount frames = original ? 44100 * 90 : 44100 * 22;
    AVAudioPCMBuffer *buffer = VibeToneBuffer(frames, 44100, 2, AVAudioPCMFormatInt16);
    if (!original) memset(buffer.int16ChannelData[0], 0, frames * 2 * sizeof(int16_t));
    if ([extension isEqualToString:@"m4a"]) {
        @autoreleasepool {
            AVAudioFile *file = [[AVAudioFile alloc] initForWriting:url
                                                           settings:@{AVFormatIDKey: @(kAudioFormatMPEG4AAC),
                                                                      AVSampleRateKey: @44100,
                                                                      AVNumberOfChannelsKey: @2}
                                                       commonFormat:AVAudioPCMFormatInt16 interleaved:YES
                                                              error:&error];
            XCTAssertTrue([file writeFromBuffer:buffer error:&error], @"%@", error);
        }
        return url;
    }
    XCTAssertNotNil(VibeWriteFixture(url, buffer, &error), @"%@: %@", name, error);
    return url;
}

- (void)probe:(NSString *)name swap:(BOOL)swap {
    NSURL *original = [self write:name original:YES];
    NSNumber *size = nil;
    [original getResourceValue:&size forKey:NSURLFileSizeKey error:NULL];
    XCTAssertGreaterThan(size.unsignedLongLongValue, 1000000ull, @"%@ is megabytes long", name);
    NSURL *reference = [_dir URLByAppendingPathComponent:[@"reference." stringByAppendingString:name.pathExtension]];
    XCTAssertTrue([NSFileManager.defaultManager copyItemAtURL:original toURL:reference error:NULL]);
    NSData *expected = VibeDecodeFile(reference);
    XCTAssertGreaterThan(expected.length, 0u, @"%@ decodes", name);

    NSError *error = nil;
    AudioFileHandle *handle = VibeTestFileOpener(original, ^BOOL { return NO; }, &error);
    XCTAssertNotNil(handle, @"%@: %@", name, error);
    NSMutableData *capture = [NSMutableData data];
    AVAudioPCMBuffer *first = [[AVAudioPCMBuffer alloc] initWithPCMFormat:handle.processingFormat frameCapacity:4096];
    XCTAssertTrue([handle readIntoBuffer:first error:&error], @"%@: %@", name, error);
    VibeAppendPCM(capture, first);

    NSURL *copy = [self write:[@"copy." stringByAppendingString:name] original:NO];
    if (swap) {
        XCTAssertEqual(renamex_np(copy.fileSystemRepresentation, original.fileSystemRepresentation, RENAME_SWAP), 0,
                       @"%@: %s", name, strerror(errno));
    }
    else {
        XCTAssertEqual(rename(copy.fileSystemRepresentation, original.fileSystemRepresentation), 0,
                       @"%@: %s", name, strerror(errno));
    }
    NSData *replaced = VibeDecodeFile(original);
    XCTAssertNotNil(replaced, @"%@: the copy decodes", name);
    XCTAssertNotEqualObjects(replaced, expected, @"%@: the path holds the copy", name);

    XCTAssertTrue(VibeReadToEnd(handle, capture, &error), @"%@ swap %d: %@", name, swap, error);
    // TRAP: two of Apple's AAC decodes in one process can differ in rounding,
    // by an ulp or two, depending on where the build puts its buffers. So AAC
    // is held to four float epsilons, as the streaming tests hold it, and
    // every other decoder to its exact samples.
    XCTAssertEqual(capture.length, expected.length, @"%@ swap %d: the open handle reads the original to its end", name, swap);
    const float *got = capture.bytes, *want = expected.bytes;
    float tolerance = [name.pathExtension isEqualToString:@"m4a"] ? 4 * FLT_EPSILON : 0;
    for (NSUInteger i = 0; i < MIN(capture.length, expected.length) / sizeof(float); i++) {
        if (fabsf(got[i] - want[i]) > tolerance) {
            XCTFail(@"%@ swap %d: the open handle reads the original to its end: sample %lu differs", name, swap, (unsigned long)i);
            break;
        }
    }
}

- (NSArray<NSString *> *)formats {
    return @[@"song.wav", @"song.aif", @"song.flac", @"song.mp3", @"song.m4a", @"song.ogg", @"song.opus"];
}

- (void)testAnOpenHandleReadsTheOriginalAfterARenameOverIt {
    for (NSString *name in self.formats) [self probe:name swap:NO];
}

- (void)testAnOpenHandleReadsTheOriginalAfterARenameSwap {
    for (NSString *name in self.formats) [self probe:name swap:YES];
}

@end
