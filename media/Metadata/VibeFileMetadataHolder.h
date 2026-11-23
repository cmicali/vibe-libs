//
//  VibeFileMetadataHolder.h
//  vibe-libs
//
//  A default holder for an app that keeps no item of its own: one file,
//  whole or a CUE window of it, and the metadata a loader installs. A fresh
//  object per call, so two holders for one file stay two holders.
//

#import <Foundation/Foundation.h>

#import "AudioTrackMetadataHolder.h"

NS_ASSUME_NONNULL_BEGIN

@interface VibeFileMetadataHolder : NSObject <AudioTrackMetadataHolder>

// The whole file.
- (instancetype)initWithURL:(NSURL *)url;
// A window of the file in CD frames, start inclusive and end exclusive. An end
// of 0 runs to the file's end.
- (instancetype)initWithURL:(NSURL *)url cueStart:(NSUInteger)cueStart cueEnd:(NSUInteger)cueEnd
        NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
