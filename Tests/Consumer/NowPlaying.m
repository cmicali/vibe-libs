//
//  NowPlaying.m
//
//  Builds the Now Playing controller with its commands registered, pushes a
//  playing track's title and duration, and reads them back from the system's
//  Now Playing info. Then clears the slot it claimed.
//

#import <Foundation/Foundation.h>
#import <MediaPlayer/MediaPlayer.h>

#import "NowPlayingController.h"

FOUNDATION_EXTERN BOOL ConsumerPublishesNowPlaying(void);

// Takes the commands and does nothing with them.
@interface ConsumerRemote : NSObject <NowPlayingControllerDelegate>
@end

@implementation ConsumerRemote
- (void)nowPlayingControllerPlay:(NowPlayingController *)controller {}
- (void)nowPlayingControllerPause:(NowPlayingController *)controller {}
- (void)nowPlayingControllerTogglePlayPause:(NowPlayingController *)controller {}
- (void)nowPlayingControllerNextTrack:(NowPlayingController *)controller {}
- (void)nowPlayingControllerPreviousTrack:(NowPlayingController *)controller {}
- (void)nowPlayingController:(NowPlayingController *)controller seekToPosition:(NSTimeInterval)position {}
- (void)nowPlayingController:(NowPlayingController *)controller setShuffleEnabled:(BOOL)enabled {}
- (void)nowPlayingController:(NowPlayingController *)controller setRepeatMode:(VibeRepeatMode)mode {}
@end

BOOL ConsumerPublishesNowPlaying(void) {
    ConsumerRemote *remote = [ConsumerRemote new];
    NowPlayingController *controller = [[NowPlayingController alloc] initWithDelegate:remote];
    [controller updateWithRecord:(VibeNowPlayingRecord){
        .sourceKey = @"/consumer/now-playing.wav",
        .title = @"Consumer",
        .position = 3,
        .duration = 42,
        .state = NowPlayingPlaybackStatePlaying,
        .rate = 1,
    }];
    NSDictionary *info = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo;
    BOOL published = [info[MPMediaItemPropertyTitle] isEqual:@"Consumer"]
            && [info[MPMediaItemPropertyPlaybackDuration] isEqual:@42]
            && info[MPMediaItemPropertyArtist] == nil;
    [controller updateWithRecord:(VibeNowPlayingRecord){.state = NowPlayingPlaybackStateStopped, .rate = 1}];
    BOOL cleared = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo == nil;
    if (!published || !cleared) {
        fprintf(stderr, "consumer: Now Playing read back %s, and %s cleared\n", info.description.UTF8String,
                cleared ? "was" : "was not");
        return NO;
    }
    return YES;
}
