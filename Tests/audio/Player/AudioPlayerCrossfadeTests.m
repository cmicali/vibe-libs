//
//  AudioPlayerCrossfadeTests.m
//
//  The whole player on the frame-driven pump, through a crossfade and what
//  comes after it.
//

#import "AudioPlayerCodedTestCase.h"

@interface AudioPlayerCrossfadeTests : AudioPlayerCodedTestCase
@end

@implementation AudioPlayerCrossfadeTests

// A declicked play never crossfades, so it ends an older crossfade too: the
// track still fading out is cut to the declick with the voice the play
// replaces. An app that crossfades only at a track's end plays its skips
// declicked, and a skip during that fade must not leave the track before it
// sounding under the new one. After the new play's fade in, every frame is
// its own.
- (void)testADeclickedPlayCutsAnOlderFade {
    [self makePlayer];
    _player.crossfadeMilliseconds = 500;
    [self playTrack:[VibeTestTrack withURL:_files[1]]];
    [self render:9600];
    NSUInteger starts = [self count:@"start"];
    [_player play:[VibeTestTrack withURL:_files[2]]];
    [self settleUntil:^BOOL { return [self count:@"start"] > starts; }];
    [self render:4800];
    XCTAssertEqualObjects(_player.debugRenderCounts[@"retiredFades"], @1, @"file 1 fades out");
    [self playTrack:[VibeTestTrack withURL:_files[3]]];
    [self render:9600];
    XCTAssertEqualObjects(_player.debugRenderCounts[@"retiredFades"], @0, @"the declicked play cut the fade");
    NSUInteger start = [self indexOfFile:3 frame:kCodedDeclickFrames gain:1];
    XCTAssertNotEqual(start, NSNotFound, @"file 3 plays alone after its fade in");
    [self assertFile:3 gain:1 from:kCodedDeclickFrames count:4800 atIndex:start in:@"after the cut"];
}

@end
