//
//  AudioPlayerDSDGainTests.m
//
//  The whole player on the frame-driven pump, playing DSF files at the
//  player's dsdGain: a DSD file whose item plays at unity takes it, and any
//  other file keeps its item's gain.
//

#import "AudioPlayerCodedTestCase.h"
#import "DSFFixtures.h"

@interface AudioPlayerDSDGainTests : AudioPlayerCodedTestCase
@end

@implementation AudioPlayerDSDGainTests {
    NSURL *_dsfDirectory;
    NSURL *_dsf[3];
}

- (void)setUp {
    [super setUp];
    _dsfDirectory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtURL:_dsfDirectory withIntermediateDirectories:YES attributes:nil error:NULL];
    for (NSUInteger i = 1; i <= 2; i++) {
        // Half a second of DSD64 stereo, each a different tone.
        NSData *data = VibeDSFFile(2, 1, NO, 2822400 / 2, VibeDSFSine(500.0 * i, 0.5), nil);
        _dsf[i] = [_dsfDirectory URLByAppendingPathComponent:[NSString stringWithFormat:@"tone%lu.dsf", (unsigned long)i]];
        XCTAssertTrue([data writeToURL:_dsf[i] atomically:NO]);
    }
}

- (void)tearDown {
    [super tearDown];
    [NSFileManager.defaultManager removeItemAtURL:_dsfDirectory error:NULL];
}

// Unity by default, so a DSD file plays as decoded until an app asks.
- (void)testTheDSDGainIsUnityByDefault {
    [self makePlayer];
    XCTAssertEqual(_player.dsdGain, 1.0f);
    [self playTrack:[VibeTestTrack withURL:_dsf[1]]];
    XCTAssertEqual(_player.currentFileGain, 1.0f);
}

// A DSD file whose item plays at unity takes the DSD gain. One whose item
// carries a gain keeps that gain, since it was leveled already. A PCM file
// never takes it.
- (void)testADSDFileWithNoGainOfItsOwnTakesTheDSDGain {
    [self makePlayer];
    _player.dsdGain = 2;
    [self playTrack:[VibeTestTrack withURL:_dsf[1]]];
    XCTAssertEqual(_player.currentFileGain, 2.0f);
    [self playTrack:[VibeTestTrack withURL:_dsf[1] fileGain:0.5f]];
    XCTAssertEqual(_player.currentFileGain, 0.5f, @"a leveled item keeps its gain");
    [self playTrack:[VibeTestTrack withURL:_files[1]]];
    XCTAssertEqual(_player.currentFileGain, 1.0f, @"a PCM file never takes the DSD gain");
}

// A gapless successor that is DSD queues at the DSD gain, and a park of the
// same track after the DSD gain changed moves the queued gain in place.
- (void)testAParkedDSDSuccessorFollowsTheDSDGain {
    [self makePlayer];
    _player.dsdGain = 2;
    [self playTrack:[VibeTestTrack withURL:_dsf[1]]];
    [self queueTrack:[VibeTestTrack withURL:_dsf[2]]];
    XCTAssertEqual([self voiceSnapshot].successorGain, 2.0f);
    _player.dsdGain = 1.4125376f; // +3 dB
    VibeTestTrack *again = [VibeTestTrack withURL:_dsf[2]];
    [self queueTrack:again];
    XCTAssertEqual([self voiceSnapshot].successorGain, 1.4125376f, @"the re-park took the new DSD gain");
}

// The guard holds the DSD gain too: NaN plays at unity.
- (void)testTheDSDGainIsGuarded {
    [self makePlayer];
    _player.dsdGain = NAN;
    [self playTrack:[VibeTestTrack withURL:_dsf[1]]];
    XCTAssertEqual(_player.currentFileGain, 1.0f);
}

@end
