//
//  AudioTrackMetadataCache+Debug.m
//  vibe-libs
//

#import "AudioTrackMetadataCache+Debug.h"

#if DEBUG

#import "AudioTrackMetadataCacheInternal.h"
#import "AudioTrackMetadataLoader+Debug.h"
#import "AudioFileMaterializationCoordinator.h"

@implementation AudioTrackMetadataCache (DebugMaterialization)

- (NSUInteger)debugPendingBackgroundMaterializationCount {
    return [_currentLoader debugPendingBackgroundMaterializationCount];
}

- (BOOL)debugBackgroundMaterializationHeld {
    return [AudioFileMaterializationCoordinator.sharedCoordinator
            isForegroundTransferActive];
}

- (NSDictionary *)debugPriorityLaneState {
    return [_currentLoader debugPriorityLaneState] ?: @{};
}

- (NSDictionary *)debugScanLaneState {
    return [_currentLoader debugScanLaneState] ?: @{};
}

- (void)debugSetReadingFileParser:(AudioTrackMetadata *(^)(NSURL *url))parser {
    self.readingFileParser = parser;
}

@end

#endif
