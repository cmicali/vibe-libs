//
//  VibeTestTrack.h
//
//  The player's tests' own playable item: a file and its window, with the
//  keys an app's item gives. A fresh object per call, so two tracks for one
//  file stay two tracks, as two rows of an app's playlist do.
//

#import <Foundation/Foundation.h>

#import "VibePlayableItem.h"

NS_ASSUME_NONNULL_BEGIN

@interface VibeTestTrack : NSObject <VibePlayableItem>
+ (VibeTestTrack *)withURL:(NSURL *)url;
// The whole file, played at `fileGain`.
+ (VibeTestTrack *)withURL:(NSURL *)url fileGain:(float)fileGain;
// The whole file, played at `fileGain`, or at `dsdFileGain` once it opens as DSD.
+ (VibeTestTrack *)withURL:(NSURL *)url fileGain:(float)fileGain dsdFileGain:(float)dsdFileGain;
// A window of the file in CD frames; an end of 0 runs to the file's end.
- (instancetype)initWithURL:(NSURL *)url cueStart:(NSUInteger)cueStart cueEnd:(NSUInteger)cueEnd;
- (instancetype)initWithURL:(NSURL *)url cueStart:(NSUInteger)cueStart cueEnd:(NSUInteger)cueEnd
                   fileGain:(float)fileGain NS_DESIGNATED_INITIALIZER;
@property (readonly) float fileGain;
// The DSD gain. A track made without one doesn't answer to it.
@property (readonly) float dsdFileGain;
- (instancetype)init NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END
