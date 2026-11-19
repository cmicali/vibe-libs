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

// While set, a write that goes to a file stops after the file is written and
// before its row, as a crash there would.
- (void)setStopsBeforeFileRowForTesting:(BOOL)stops;

// Writes the uses that reads recorded, which a store writes a moment later.
- (void)recordUsesNowForTesting;

// The names of the files under the store's folder of files.
- (NSArray<NSString *> *)fileNamesForTesting;

@end

NS_ASSUME_NONNULL_END
