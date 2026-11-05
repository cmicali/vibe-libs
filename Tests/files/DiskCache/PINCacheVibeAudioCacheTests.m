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

#pragma mark - Records on demand

// The records a store keeps in memory, which a store made here never has.
static NSUInteger VibeRecordsKept(PINDiskCache *cache) {
    return [[cache valueForKey:@"metadata"] count];
}

// Waits until the store has read its directory once, as its enumeration does.
static void VibeWaitForDiskState(PINDiskCache *cache) {
    [cache enumerateObjectsWithBlock:^(NSString *key, NSURL *fileURL, BOOL *stop) {
        *stop = YES;
    }];
}

// The bytes the store's files take on disk, as it counts them.
static NSUInteger VibeAllocatedBytes(PINDiskCache *cache) {
    NSUInteger bytes = 0;
    for (NSURL *file in [NSFileManager.defaultManager contentsOfDirectoryAtURL:cache.cacheURL
                                                   includingPropertiesForKeys:@[NSURLTotalFileAllocatedSizeKey]
                                                                      options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                        error:nil]) {
        NSNumber *size = nil;
        [file getResourceValue:&size forKey:NSURLTotalFileAllocatedSizeKey error:nil];
        bytes += size.unsignedIntegerValue;
    }
    return bytes;
}

// A store keeps no record of its entries in memory, and reads each from its
// file: a hit, a miss, and whether it holds a key.
- (void)testAStoreKeepsNoRecordOfItsEntries {
    PINDiskCache *cache = [PINCache audioCacheWithName:@"records" rootPath:_root].diskCache;
    XCTAssertTrue(cache.recordsOnDemand);
    [cache setObject:[NSMutableData dataWithLength:1000] forKey:@"one"];
    [cache setObject:[NSMutableData dataWithLength:2000] forKey:@"two"];
    VibeWaitForDiskState(cache);
    XCTAssertEqual(VibeRecordsKept(cache), 0u);
    XCTAssertEqual([(NSData *)[cache objectForKey:@"two"] length], 2000u);
    XCTAssertNil([cache objectForKey:@"three"]);
    XCTAssertTrue([cache containsObjectForKey:@"one"]);
    XCTAssertFalse([cache containsObjectForKey:@"three"]);
    __block NSUInteger listed = 0;
    [cache enumerateObjectsWithBlock:^(NSString *key, NSURL *fileURL, BOOL *stop) {
        listed++;
    }];
    XCTAssertEqual(listed, 2u);
    XCTAssertEqual(VibeRecordsKept(cache), 0u);
}

// The byte count follows each write, each write over an entry, and each
// removal, with no record to read the old size from.
- (void)testItsByteCountFollowsEveryWriteAndRemoval {
    PINDiskCache *cache = [PINCache audioCacheWithName:@"bytes" rootPath:_root].diskCache;
    VibeWaitForDiskState(cache);
    [cache setObject:[NSMutableData dataWithLength:1000] forKey:@"one"];
    [cache setObject:[NSMutableData dataWithLength:30000] forKey:@"two"];
    XCTAssertEqual(cache.byteCount, VibeAllocatedBytes(cache));
    [cache setObject:[NSMutableData dataWithLength:90000] forKey:@"one"];
    XCTAssertEqual(cache.byteCount, VibeAllocatedBytes(cache));
    [cache removeObjectForKey:@"two"];
    XCTAssertEqual(cache.byteCount, VibeAllocatedBytes(cache));
    XCTAssertGreaterThan(cache.byteCount, 0u);
}

// A store opened again counts the bytes its files take, and keeps no records.
- (void)testAStoreOpenedAgainCountsItsFiles {
    PINDiskCache *first = [PINCache audioCacheWithName:@"again" rootPath:_root].diskCache;
    [first setObject:[NSMutableData dataWithLength:5000] forKey:@"one"];
    [first setObject:[NSMutableData dataWithLength:7000] forKey:@"two"];
    NSUInteger bytes = VibeAllocatedBytes(first);
    PINDiskCache *again = [PINCache audioCacheWithName:@"again" rootPath:_root].diskCache;
    VibeWaitForDiskState(again);
    XCTAssertEqual(again.byteCount, bytes);
    XCTAssertEqual(VibeRecordsKept(again), 0u);
}

// A trim by size removes the entries used longest ago first, by their files'
// dates.
- (void)testATrimRemovesTheLeastRecentlyUsedFirst {
    PINDiskCache *cache = [PINCache audioCacheWithName:@"trim" rootPath:_root].diskCache;
    VibeWaitForDiskState(cache);
    NSArray<NSString *> *keys = @[@"oldest", @"older", @"newest"];
    for (NSUInteger i = 0; i < keys.count; i++) {
        [cache setObject:[NSMutableData dataWithLength:10000] forKey:keys[i]];
        NSURL *file = [cache fileURLForKey:keys[i]];
        NSDate *used = [NSDate dateWithTimeIntervalSinceNow:-86400.0 * (10 - i)];
        XCTAssertTrue([NSFileManager.defaultManager setAttributes:@{NSFileModificationDate: used}
                                                     ofItemAtPath:file.path error:nil]);
    }
    NSUInteger one = VibeAllocatedBytes(cache) / 3;
    [cache trimToSizeByEvictionStrategy:one];
    XCTAssertFalse([cache containsObjectForKey:@"oldest"]);
    XCTAssertFalse([cache containsObjectForKey:@"older"]);
    XCTAssertTrue([cache containsObjectForKey:@"newest"]);
    XCTAssertEqual(cache.byteCount, VibeAllocatedBytes(cache));
}

// A trim to a date removes the entries made before it, by their files'
// creation dates.
- (void)testATrimToADateRemovesTheEntriesMadeBefore {
    PINDiskCache *cache = [PINCache audioCacheWithName:@"dated" rootPath:_root].diskCache;
    VibeWaitForDiskState(cache);
    [cache setObject:[NSMutableData dataWithLength:1000] forKey:@"old"];
    NSURL *old = [cache fileURLForKey:@"old"];
    [cache setObject:[NSMutableData dataWithLength:1000] forKey:@"new"];
    XCTAssertTrue([NSFileManager.defaultManager setAttributes:@{NSFileCreationDate: [NSDate dateWithTimeIntervalSinceNow:-86400.0 * 200]}
                                                 ofItemAtPath:old.path error:nil]);
    [cache trimToDate:[NSDate dateWithTimeIntervalSinceNow:-86400.0 * 180]];
    XCTAssertFalse([cache containsObjectForKey:@"old"]);
    XCTAssertTrue([cache containsObjectForKey:@"new"]);
}

// A plain store keeps a record of each entry. Asked for records on demand, it
// drops them, and keeps its byte count.
- (void)testRecordsOnDemandDropsTheRecordsKept {
    PINDiskCache *cache = [[PINCache alloc] initWithName:@"plain" rootPath:_root].diskCache;
    VibeWaitForDiskState(cache);
    [cache setObject:[NSMutableData dataWithLength:4000] forKey:@"one"];
    XCTAssertEqual(VibeRecordsKept(cache), 1u);
    NSUInteger bytes = cache.byteCount;
    cache.recordsOnDemand = YES;
    XCTAssertEqual(VibeRecordsKept(cache), 0u);
    XCTAssertEqual(cache.byteCount, bytes);
    XCTAssertEqual([(NSData *)[cache objectForKey:@"one"] length], 4000u);
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
