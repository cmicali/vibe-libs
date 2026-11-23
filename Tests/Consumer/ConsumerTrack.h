//
//  ConsumerTrack.h
//
//  The consumer's row: Metadata's default holder, a file whole or a CUE
//  window of it. The player, the metadata cache, and the waveform cache each
//  take it and hand the same object back. The queue holds it as an opaque
//  entry.
//

#import <Foundation/Foundation.h>

#import "VibeFileMetadataHolder.h"

NS_ASSUME_NONNULL_BEGIN

@interface ConsumerTrack : VibeFileMetadataHolder

// The whole file.
+ (ConsumerTrack *)withURL:(NSURL *)url;

@end

NS_ASSUME_NONNULL_END
