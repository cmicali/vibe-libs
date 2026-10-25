//
//  NowPlayingController.h
//  vibe-libs
//
//  The MPRemoteCommandCenter / MPNowPlayingInfoCenter bridge. It owns no
//  playback state. The app drives it and takes the commands back through the
//  delegate.
//
//  TRAP: making one claims the system's media slot. Registering the commands
//  and publishing can pull AirPods from another device, even while the app
//  renders to a virtual output. An app's test launch makes none.
//

#import <Foundation/Foundation.h>
#import "PlatformTypes.h"
#import "RepeatMode.h"

NS_ASSUME_NONNULL_BEGIN

@class NowPlayingController;

// Loading maps by its intent: an ordinary load is Playing, a parked one Paused.
typedef NS_ENUM(NSInteger, NowPlayingPlaybackState) {
    NowPlayingPlaybackStateStopped = 0,
    NowPlayingPlaybackStatePlaying,
    NowPlayingPlaybackStatePaused,
};

// One update's values. The app fills a fresh record on every transport event
// and passes it by value, so a later change on the app's side never reaches
// what was published. A field left out reads as nil, zero, or NO.
typedef struct {
    // The track's identity for the dirty check, so a cue row of the same file
    // is a change. nil means no track.
    NSString *_Nullable sourceKey;
    // nil publishes as empty.
    NSString *_Nullable title;
    // nil publishes none.
    NSString *_Nullable artist;
    // The track's art, else its thumbnail, else the app's placeholder, each
    // read without blocking. The thumbnail covers the gap until the full art
    // decodes. The placeholder must already match the app's appearance, since
    // the drawing appearance here is the system's. Pass the same image while
    // it is unchanged, since the dirty check compares identity.
    VibeImage *_Nullable artwork;
    // Seconds from the track start.
    NSTimeInterval position;
    // 0 publishes none.
    NSTimeInterval duration;
    NowPlayingPlaybackState state;
    // How fast position advances in real time. 0 holds the system's clock.
    double rate;
    // Gate the system's next and previous commands, even before the first
    // publish.
    BOOL hasNext;
    BOOL hasPrevious;
} VibeNowPlayingRecord;

@protocol NowPlayingControllerDelegate <NSObject>
// Destination states, not a toggle: route them to idempotent operations.
- (void)nowPlayingControllerPlay:(NowPlayingController *)controller;
- (void)nowPlayingControllerPause:(NowPlayingController *)controller;
- (void)nowPlayingControllerTogglePlayPause:(NowPlayingController *)controller;
- (void)nowPlayingControllerNextTrack:(NowPlayingController *)controller;
- (void)nowPlayingControllerPreviousTrack:(NowPlayingController *)controller;
// Seconds from the track start.
- (void)nowPlayingController:(NowPlayingController *)controller seekToPosition:(NSTimeInterval)position;
// The system's shuffle and repeat controls (Siri, the Watch, accessories):
// write the setting and apply it as the app's own control does.
- (void)nowPlayingController:(NowPlayingController *)controller setShuffleEnabled:(BOOL)enabled;
- (void)nowPlayingController:(NowPlayingController *)controller setRepeatMode:(VibeRepeatMode)mode;
@end

@interface NowPlayingController : NSObject

// Registers the remote command handlers at once.
- (instancetype)initWithDelegate:(id<NowPlayingControllerDelegate>)delegate;

// Publication only, no command registration: the tests' OS boundary.
- (instancetype)initWithClock:(NSTimeInterval (^)(void))clock
                      publish:(void (^)(NSDictionary * _Nullable, NowPlayingPlaybackState))publish
          commandAvailability:(void (^)(BOOL hasNext, BOOL hasPrevious))commandAvailability;

// Nothing is published until the first Playing update, so a launch never
// claims the system slot. After that, a nil sourceKey clears it once. A dirty
// check skips unchanged publishes, so this is cheap on every transport event.
// Main thread.
- (void)updateWithRecord:(VibeNowPlayingRecord)record;

// The modes the system's controls show, and whether they offer them at all:
// unavailable, CarPlay draws neither button. There is no Now Playing info key
// for either: the state lives on the commands, so it is written wherever a
// mode is applied, whoever changed it. Main thread.
- (void)updateShuffleEnabled:(BOOL)shuffleEnabled
                  repeatMode:(VibeRepeatMode)repeatMode
                   available:(BOOL)available;

@end

NS_ASSUME_NONNULL_END
