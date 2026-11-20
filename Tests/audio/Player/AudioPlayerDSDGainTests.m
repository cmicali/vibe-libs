//
//  AudioPlayerDSDGainTests.m
//
//  The whole player on the frame-driven pump, playing DSF files at their
//  items' dsdFileGain: a DSD file takes it, and a PCM file keeps the item's
//  fileGain.
//

#import "AudioPlayerCodedTestCase.h"
#import "DSFFixtures.h"

@interface AudioPlayerDSDGainTests : AudioPlayerCodedTestCase
@end

@implementation AudioPlayerDSDGainTests {
    NSURL *_dsf[3];
}

- (void)setUp {
    [super setUp];
    for (NSUInteger i = 1; i <= 2; i++) {
        // Half a second of DSD64 stereo, each a different tone.
        NSData *data = VibeDSFFile(2, 1, NO, 2822400 / 2, VibeDSFSine(500.0 * i, 0.5), nil);
        _dsf[i] = [_temporary URLByAppendingPathComponent:[NSString stringWithFormat:@"tone%lu.dsf", (unsigned long)i]];
        XCTAssertTrue([data writeToURL:_dsf[i] atomically:NO]);
    }
}

// A DSD file plays at the item's DSD gain, and without one at its fileGain.
// A PCM file plays at its fileGain whatever its DSD gain.
- (void)testADSDFilePlaysAtItsItemsDSDGain {
    [self makePlayer];
    [self playTrack:[VibeTestTrack withURL:_dsf[1] fileGain:0.5f dsdFileGain:2]];
    XCTAssertEqual(_player.currentFileGain, 2.0f);
    [self playTrack:[VibeTestTrack withURL:_dsf[1] fileGain:0.5f]];
    XCTAssertEqual(_player.currentFileGain, 0.5f, @"no DSD gain: its fileGain");
    [self playTrack:[VibeTestTrack withURL:_files[1] fileGain:0.5f dsdFileGain:2]];
    XCTAssertEqual(_player.currentFileGain, 0.5f, @"a PCM file never takes the DSD gain");
}

// A gapless successor that is DSD queues at its DSD gain, and a park of the
// same track at another DSD gain moves the queued gain in place.
- (void)testAParkedDSDSuccessorTakesItsDSDGain {
    [self makePlayer];
    [self playTrack:[VibeTestTrack withURL:_dsf[1] fileGain:1 dsdFileGain:2]];
    [self queueTrack:[VibeTestTrack withURL:_dsf[2] fileGain:1 dsdFileGain:2]];
    XCTAssertEqual([self voiceSnapshot].successorGain, 2.0f);
    [self queueTrack:[VibeTestTrack withURL:_dsf[2] fileGain:1 dsdFileGain:1.4125376f]];
    XCTAssertEqual([self voiceSnapshot].successorGain, 1.4125376f, @"the re-park moved the gain");
}

@end
