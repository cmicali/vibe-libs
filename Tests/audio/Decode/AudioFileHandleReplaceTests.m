//
//  AudioFileHandleReplaceTests.m
//  vibe-libs
//
//  The probe behind a tag editor's safe write: a copy of the file is
//  rewritten and swapped in while a player reads the original. An open
//  handle holds the file's descriptor, or CoreAudio's, so it reads the
//  original's bytes to their end, whichever way the copy is swapped in:
//  rename(2) over the path, or renamex_np's RENAME_SWAP. Each decoder's open
//  is probed: dr_wav, dr_flac, dr_mp3, and CoreAudio's parser for AAC.
//

#import <XCTest/XCTest.h>
#import <AVFoundation/AVFoundation.h>
#include <stdio.h>

#import "AudioFileHandle.h"
#import "AudioFileFixtures.h"

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

// The original, `frames` of the tone, or the copy that replaces it: a
// quarter as long and silent, so a read of its bytes cannot pass for the
// original's.
- (NSURL *)write:(NSString *)name original:(BOOL)original {
    NSURL *url = [_dir URLByAppendingPathComponent:name];
    const AVAudioFrameCount frames = original ? 88200 : 22050;
    NSString *extension = name.pathExtension;
    NSError *error = nil;
    if ([extension isEqualToString:@"mp3"]) {
        XCTAssertTrue([VibeMP3WithInfoFrame(original ? 76 : 19, NO) writeToURL:url atomically:NO]);
        return url;
    }
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

// Every frame a handle reads from its cursor to the end, in chunks. NO, with
// the failure, when a read fails.
static BOOL VibeReadToEnd(AudioFileHandle *handle, NSMutableData *capture, NSError **error) {
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:handle.processingFormat frameCapacity:4096];
    while (YES) {
        if (![handle readIntoBuffer:buffer error:error]) return NO;
        if (buffer.frameLength == 0) return YES;
        VibeAppendPCM(capture, buffer);
    }
}

static NSData *VibeDecode(NSURL *url) {
    AudioFileHandle *handle = [[AudioFileHandle alloc] initForReading:url error:NULL];
    NSMutableData *capture = [NSMutableData data];
    return handle && VibeReadToEnd(handle, capture, NULL) ? capture : nil;
}

- (void)probe:(NSString *)name swap:(BOOL)swap {
    NSURL *original = [self write:name original:YES];
    NSURL *reference = [_dir URLByAppendingPathComponent:[@"reference." stringByAppendingString:name.pathExtension]];
    XCTAssertTrue([NSFileManager.defaultManager copyItemAtURL:original toURL:reference error:NULL]);
    NSData *expected = VibeDecode(reference);
    XCTAssertGreaterThan(expected.length, 0u, @"%@", name);

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
    NSData *replaced = VibeDecode(original);
    XCTAssertLessThan(replaced.length, expected.length, @"%@: the path holds the copy", name);

    XCTAssertTrue(VibeReadToEnd(handle, capture, &error), @"%@ swap %d: %@", name, swap, error);
    XCTAssertEqualObjects(capture, expected, @"%@ swap %d: the open handle reads the original to its end", name, swap);
}

- (void)testAnOpenHandleReadsTheOriginalAfterARenameOverIt {
    for (NSString *name in @[@"song.wav", @"song.aif", @"song.flac", @"song.mp3", @"song.m4a"]) {
        [self probe:name swap:NO];
    }
}

- (void)testAnOpenHandleReadsTheOriginalAfterARenameSwap {
    for (NSString *name in @[@"song.wav", @"song.aif", @"song.flac", @"song.mp3", @"song.m4a"]) {
        [self probe:name swap:YES];
    }
}

@end
