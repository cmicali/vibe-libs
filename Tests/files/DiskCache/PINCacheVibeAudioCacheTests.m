//
// The bounded disk cache: a store under a root of the caller's, with the
// shared byte and age limits, its usage on disk, and the removal of the
// stores other versions left.
//

#import <XCTest/XCTest.h>

#import "PINCache+VibeAudioCache.h"

@interface PINCacheVibeAudioCacheTests : XCTestCase
@end

@implementation PINCacheVibeAudioCacheTests {
    NSString *_root;
}

- (void)setUp {
    [super setUp];
    _root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
}

- (void)tearDown {
    [NSFileManager.defaultManager removeItemAtPath:_root error:nil];
    [super tearDown];
}

// TRAP: PINDiskCache sets each limit on its own queue, so a read right after
// the store is made can still see the default.
- (void)testAStoreUnderARootHasTheSharedLimits {
    PINCache *cache = [PINCache audioCacheWithName:@"limits" rootPath:_root];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:VIBE_TEST_HANG_TIMEOUT];
    while ((cache.diskCache.byteLimit != 1024u * 1024u * 1024u || cache.diskCache.ageLimit != 180.0 * 24 * 60 * 60)
            && deadline.timeIntervalSinceNow > 0) {
        [NSThread sleepForTimeInterval:0.01];
    }
    XCTAssertEqual(cache.diskCache.byteLimit, 1024u * 1024u * 1024u);
    XCTAssertEqual(cache.diskCache.ageLimit, 180.0 * 24 * 60 * 60);
    XCTAssertTrue([cache.diskCache.cacheURL.path hasPrefix:_root], @"%@", cache.diskCache.cacheURL.path);
}

- (void)testUsageCountsEveryEntryAndItsBytesOnMain {
    PINCache *cache = [PINCache audioCacheWithName:@"usage" rootPath:_root];
    [cache.diskCache setObject:[NSMutableData dataWithLength:1000] forKey:@"one"];
    [cache.diskCache setObject:[NSMutableData dataWithLength:3000] forKey:@"two"];
    XCTestExpectation *counted = [self expectationWithDescription:@"counted"];
    [cache audioDiskUsageWithCompletion:^(NSUInteger fileCount, unsigned long long totalBytes) {
        XCTAssertTrue(NSThread.isMainThread);
        XCTAssertEqual(fileCount, 2u);
        XCTAssertGreaterThanOrEqual(totalBytes, 4000u);
        [counted fulfill];
    }];
    [self waitForExpectations:@[counted] timeout:VIBE_TEST_HANG_TIMEOUT];
}

#pragma mark - Other versions' stores

- (void)makeStores:(NSArray<NSString *> *)names {
    for (NSString *name in names) {
        NSString *store = [_root stringByAppendingPathComponent:name];
        XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtPath:store withIntermediateDirectories:YES
                                                               attributes:nil error:nil]);
        [NSData.data writeToFile:[store stringByAppendingPathComponent:@"entry"] atomically:NO];
    }
}

- (NSSet<NSString *> *)remaining {
    return [NSSet setWithArray:[NSFileManager.defaultManager contentsOfDirectoryAtPath:_root error:nil] ?: @[]];
}

- (void)removeOtherVersionsKeeping:(NSArray<NSString *> *)names under:(NSString *)root {
    XCTestExpectation *removed = [self expectationWithDescription:@"removed"];
    [PINCache removeOtherAudioCacheVersionsKeeping:names rootPath:root completion:^{
        [removed fulfill];
    }];
    [self waitForExpectations:@[removed] timeout:VIBE_TEST_HANG_TIMEOUT];
}

// Every name a release shipped, with the next bump's current names standing in.
- (void)testRemovesEveryOtherVersionAndKeepsTheCurrentStores {
    NSMutableArray<NSString *> *legacy = [NSMutableArray array];
    for (NSString *name in @[@"Audio Track Metadata", @"Audio Track Metadata v2", @"Audio Track Metadata v3",
                             @"Audio Track Metadata v4", @"Audio Track Metadata v5", @"Audio Track Metadata v7",
                             @"Audio Track Metadata v10", @"audio_waveform_cache", @"audio_waveform_cache_v2",
                             @"audio_waveform_cache_v4", @"audio_waveform_cache_v5", @"audio_waveform_cache_v6"]) {
        [legacy addObject:[@"com.pinterest.PINDiskCache." stringByAppendingString:name]];
    }
    NSArray<NSString *> *kept = @[@"com.pinterest.PINDiskCache.Audio Track Metadata v8",
                                  @"com.pinterest.PINDiskCache.audio_waveform_cache_v7",
                                  // Another store, and a directory that is no store.
                                  @"com.pinterest.PINDiskCache.Audio Track Metadata Art v1",
                                  @"Audio Track Metadata v5"];
    [self makeStores:[legacy arrayByAddingObjectsFromArray:kept]];

    [self removeOtherVersionsKeeping:@[@"Audio Track Metadata v8", @"audio_waveform_cache_v7"] under:_root];

    XCTAssertEqualObjects(self.remaining, [NSSet setWithArray:kept]);
}

// The store audioCacheWithName: makes is the one the rule keeps.
- (void)testTheRuleKeepsTheStoreItsHelperMakes {
    PINCache *cache = [PINCache audioCacheWithName:@"store_v3" rootPath:_root];
    [cache.diskCache setObject:NSData.data forKey:@"entry"];
    NSString *current = cache.diskCache.cacheURL.lastPathComponent;
    [self makeStores:@[@"com.pinterest.PINDiskCache.store_v2"]];

    [self removeOtherVersionsKeeping:@[@"store_v3"] under:_root];

    XCTAssertEqualObjects(self.remaining, [NSSet setWithObject:current]);
}

- (void)testAMissingDirectoryIsANoOp {
    [self removeOtherVersionsKeeping:@[@"Audio Track Metadata v8"]
                               under:[_root stringByAppendingPathComponent:@"absent"]];
    XCTAssertEqualObjects(self.remaining, [NSSet set]);
}

@end
