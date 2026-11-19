//
//  VibeCacheStore+Testing.h
//  vibe-libs
//
//  Seams for the store's tests. Each body is empty outside DEBUG.
//

#import "VibeCacheStore.h"

NS_ASSUME_NONNULL_BEGIN

@interface VibeCacheStore (Testing)

// Moves the store's today by `days`, for the age limit and the daily use.
- (void)setDayOffsetForTesting:(NSInteger)days;

// Writes the uses that reads recorded, which a store writes a moment later.
- (void)recordUsesNowForTesting;

@end

NS_ASSUME_NONNULL_END
