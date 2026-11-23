//
//  ConsumerTrack.h
//
//  The consumer's row, as an app's playlist row is: a file whole, or a CUE
//  window of it. The player, the metadata cache, and the waveform cache each
//  take it and hand the same object back. The queue holds it as an opaque
//  entry. A fresh object per row, so two rows of one file stay two. It is
//  Metadata's default holder, so an app with no row type of its own can take
//  that one.
//

#import <Foundation/Foundation.h>

#import "VibeFileMetadataHolder.h"

NS_ASSUME_NONNULL_BEGIN

@interface ConsumerTrack : VibeFileMetadataHolder

// The whole file.
+ (ConsumerTrack *)withURL:(NSURL *)url;

@end

NS_ASSUME_NONNULL_END
