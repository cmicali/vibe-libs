//
//  VibeWidgetState.h
//  vibe-libs
//
//  What the app publishes and the widget draws. COMPILED INTO BOTH TARGETS, so
//  Foundation only: the extension links no app class. Every field is "what was
//  true at positionDate"; the widget derives the playhead from that instant.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VibeWidgetState : NSObject <NSCopying>

#pragma mark - Which app

// Set once by each process before its first read or write: the app at
// launch, and the extension when its widget bundle is made. Until then
// containerURL is nil. Both targets' entitlements must carry the group. A
// second call with other values asserts, since the container is resolved once.
+ (void)useAppGroup:(NSString *)appGroup readNotification:(NSString *)readNotification
        NS_SWIFT_NAME(use(appGroup:readNotification:));

// The Darwin notification loadState posts, which turns publishing on, gallery
// previews included. nil until set.
@property (class, nonatomic, readonly, nullable) NSString *readNotification;

// A nil artist means a single line, such as one derived from the filename.
@property (nonatomic, copy, nullable) NSString *title;
@property (nonatomic, copy, nullable) NSString *artist;
@property (nonatomic) BOOL hasTrack;
@property (nonatomic) BOOL playing;
@property (nonatomic) NSTimeInterval duration;

// The publisher's VibeWidgetTrackKey, nil with no track. It names the image
// files, so a publish landing between the extension's plist and image reads
// cannot pair one track's title with another's cover; and it rides in every
// seek button, so a tap on a stale render cannot seek what is playing now.
@property (nonatomic, copy, nullable) NSString *trackKey;

// Where the playhead was AT positionDate; the widget advances it itself.
@property (nonatomic) NSTimeInterval position;
@property (nonatomic, copy, nullable) NSDate *positionDate;

// YES: both waveform images are the whole strip as played, and the widget
// draws a line at the playhead. NO: the played image is revealed to it.
@property (nonatomic) BOOL playheadLine;

#pragma mark - Where it lives

// nil when the app group is not set or not provisioned; the widget draws its
// empty state.
@property (class, nonatomic, readonly, nullable) NSURL *containerURL;

// This snapshot's own images, named by its trackKey; nil with no key.
@property (nonatomic, readonly, nullable) NSURL *artworkURL;
@property (nonatomic, readonly, nullable) NSURL *waveformPlayedURL;
@property (nonatomic, readonly, nullable) NSURL *waveformUnplayedURL;
// Image files belonging to none of trackKeys.
+ (NSArray<NSURL *> *)imageURLsNotForTrackKeys:(NSArray<NSString *> *)trackKeys;

#pragma mark - Reading and writing

// Posts readNotification even when it returns nil. Returns nil when a field
// has the wrong class. The Swift names are pinned: a rename would break the
// extension, a build the app never runs.
+ (nullable VibeWidgetState *)loadState NS_SWIFT_NAME(load());
- (BOOL)save;

// Clamped to the duration. The playhead and the timeline entries share it.
- (NSTimeInterval)positionAtDate:(NSDate *)date NS_SWIFT_NAME(position(at:));
- (double)progressAtDate:(NSDate *)date NS_SWIFT_NAME(progress(at:));

@end

NS_ASSUME_NONNULL_END
