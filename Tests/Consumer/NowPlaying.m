//
//  NowPlaying.m
//
//  Builds the Now Playing controller over sinks of its own, as the piece's
//  tests do, so the check touches no system state. Pushes a playing track's
//  title and duration, and reads them back from what the controller
//  published. Then clears the slot it claimed.
//

#import <Foundation/Foundation.h>
#import <MediaPlayer/MediaPlayer.h>

#import "NowPlayingController.h"

FOUNDATION_EXTERN BOOL ConsumerPublishesNowPlaying(void);

BOOL ConsumerPublishesNowPlaying(void) {
    NSMutableArray *publications = [NSMutableArray array];
    NowPlayingController *controller = [[NowPlayingController alloc] initWithClock:^{
        return CFAbsoluteTimeGetCurrent();
    } publish:^(NSDictionary *info, NowPlayingPlaybackState state) {
        [publications addObject:info ?: NSNull.null];
    } commandAvailability:^(BOOL hasNext, BOOL hasPrevious) {
    }];
    [controller updateWithRecord:(VibeNowPlayingRecord){
        .sourceKey = @"/consumer/now-playing.wav",
        .title = @"Consumer",
        .position = 3,
        .duration = 42,
        .state = NowPlayingPlaybackStatePlaying,
        .rate = 1,
    }];
    NSDictionary *info = [publications.lastObject isKindOfClass:NSDictionary.class] ? publications.lastObject : nil;
    BOOL published = [info[MPMediaItemPropertyTitle] isEqual:@"Consumer"]
            && [info[MPMediaItemPropertyPlaybackDuration] isEqual:@42]
            && info[MPMediaItemPropertyArtist] == nil;
    [controller updateWithRecord:(VibeNowPlayingRecord){.state = NowPlayingPlaybackStateStopped, .rate = 1}];
    BOOL cleared = publications.count == 2 && publications.lastObject == NSNull.null;
    if (!published || !cleared) {
        fprintf(stderr, "consumer: Now Playing published %s, and %s cleared\n", publications.description.UTF8String,
                cleared ? "was" : "was not");
        return NO;
    }
    return YES;
}
