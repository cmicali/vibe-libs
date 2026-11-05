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

// The records a store keeps in memory, which a store made here never has. Its
// private dictionary, read by key, since the cache is vendored here.
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
// creation dates, as a store opened again finds them.
- (void)testATrimToADateRemovesTheEntriesMadeBefore {
    PINDiskCache *first = [PINCache audioCacheWithName:@"dated" rootPath:_root].diskCache;
    VibeWaitForDiskState(first);
    [first setObject:[NSMutableData dataWithLength:1000] forKey:@"old"];
    [first setObject:[NSMutableData dataWithLength:1000] forKey:@"new"];
    XCTAssertTrue([NSFileManager.defaultManager setAttributes:@{NSFileCreationDate: [NSDate dateWithTimeIntervalSinceNow:-86400.0 * 100]}
                                                 ofItemAtPath:[first fileURLForKey:@"old"].path error:nil]);
    first = nil;
    PINDiskCache *cache = [PINCache audioCacheWithName:@"dated" rootPath:_root].diskCache;
    VibeWaitForDiskState(cache);
    [cache trimToDate:[NSDate dateWithTimeIntervalSinceNow:-86400.0 * 50]];
    XCTAssertFalse([cache containsObjectForKey:@"old"]);
    XCTAssertTrue([cache containsObjectForKey:@"new"]);
}

// A store that has seen no entry made before a date lists nothing to trim
// to it: an entry made older behind its back stays, until a reopening reads
// its date and trims it.
- (void)testATrimToADateListsNothingWhenNothingIsThatOld {
    PINDiskCache *cache = [PINCache audioCacheWithName:@"recent" rootPath:_root].diskCache;
    VibeWaitForDiskState(cache);
    [cache setObject:[NSMutableData dataWithLength:1000] forKey:@"one"];
    XCTAssertTrue([NSFileManager.defaultManager setAttributes:@{NSFileCreationDate: [NSDate dateWithTimeIntervalSinceNow:-86400.0 * 100]}
                                                 ofItemAtPath:[cache fileURLForKey:@"one"].path error:nil]);
    NSDate *trimDate = [NSDate dateWithTimeIntervalSinceNow:-86400.0 * 50];
    [cache trimToDate:trimDate];
    XCTAssertTrue([cache containsObjectForKey:@"one"], @"it listed nothing");
    cache = nil;
    PINDiskCache *again = [PINCache audioCacheWithName:@"recent" rootPath:_root].diskCache;
    VibeWaitForDiskState(again);
    [again trimToDate:trimDate];
    XCTAssertFalse([again containsObjectForKey:@"one"]);
}

// A plain store that read its records before the mode keeps their dates in
// the bound the mode drops them for, so an old one is still trimmed.
- (void)testRecordsDroppedForTheModeKeepTheirDates {
    PINDiskCache *first = [[PINCache alloc] initWithName:@"dropped" rootPath:_root].diskCache;
    VibeWaitForDiskState(first);
    [first setObject:[NSMutableData dataWithLength:1000] forKey:@"old"];
    XCTAssertTrue([NSFileManager.defaultManager setAttributes:@{NSFileCreationDate: [NSDate dateWithTimeIntervalSinceNow:-86400.0 * 100]}
                                                 ofItemAtPath:[first fileURLForKey:@"old"].path error:nil]);
    first = nil;
    PINDiskCache *plain = [[PINCache alloc] initWithName:@"dropped" rootPath:_root].diskCache;
    VibeWaitForDiskState(plain);
    XCTAssertEqual(VibeRecordsKept(plain), 1u);
    plain.recordsOnDemand = YES;
    [plain trimToDate:[NSDate dateWithTimeIntervalSinceNow:-86400.0 * 50]];
    XCTAssertFalse([plain containsObjectForKey:@"old"]);
}

// Removing every entry right as a store opens over its files leaves a count
// of none, not the files its launch's count saw.
- (void)testRemovingEveryEntryAtOpenLeavesNoBytes {
    PINDiskCache *first = [PINCache audioCacheWithName:@"wiped" rootPath:_root].diskCache;
    for (NSUInteger i = 0; i < 50; i++) {
        [first setObject:[NSMutableData dataWithLength:5000] forKey:[NSString stringWithFormat:@"%lu", (unsigned long)i]];
    }
    first = nil;
    PINDiskCache *again = [PINCache audioCacheWithName:@"wiped" rootPath:_root].diskCache;
    [again removeAllObjects];
    VibeWaitForDiskState(again);
    XCTAssertEqual(again.byteCount, 0u);
    XCTAssertEqual(VibeAllocatedBytes(again), 0u);
}

// A plain store's launch count reads its directory a thousand files to a
// pool, past a pool's end, and skips a hidden file, as upstream's listing did.
- (void)testAPlainStoresCountReadsEveryFile {
    PINDiskCache *first = [[PINCache alloc] initWithName:@"many" rootPath:_root].diskCache;
    VibeWaitForDiskState(first);
    NSString *directory = first.cacheURL.path;
    first = nil;
    for (NSUInteger i = 0; i < 1500; i++) {
        [NSData.data writeToFile:[directory stringByAppendingPathComponent:[NSString stringWithFormat:@"file%lu", (unsigned long)i]]
                      atomically:NO];
    }
    [[NSMutableData dataWithLength:5000] writeToFile:[directory stringByAppendingPathComponent:@".hidden"] atomically:NO];
    PINDiskCache *plain = [[PINCache alloc] initWithName:@"many" rootPath:_root].diskCache;
    VibeWaitForDiskState(plain);
    XCTAssertEqual(VibeRecordsKept(plain), 1500u);
    XCTAssertEqual(plain.byteCount, VibeAllocatedBytes(plain));
}

// A store opened again over entries made 200 days ago, written to before it
// has counted its files, ages them out and keeps the rest, with a byte count
// that never wraps below zero.
- (void)testAStoreOpenedOverOldEntriesKeepsItsCount {
    PINDiskCache *first = [PINCache audioCacheWithName:@"aged" rootPath:_root].diskCache;
    VibeWaitForDiskState(first);
    for (NSString *key in @[@"old one", @"old two", @"young"]) {
        [first setObject:[NSMutableData dataWithLength:20000] forKey:key];
    }
    NSDate *made = [NSDate dateWithTimeIntervalSinceNow:-86400.0 * 200];
    for (NSString *key in @[@"old one", @"old two"]) {
        XCTAssertTrue([NSFileManager.defaultManager setAttributes:@{NSFileCreationDate: made}
                                                     ofItemAtPath:[first fileURLForKey:key].path error:nil]);
    }
    first = nil;
    PINDiskCache *again = [PINCache audioCacheWithName:@"aged" rootPath:_root].diskCache;
    [again setObject:[NSMutableData dataWithLength:1000] forKey:@"new"];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:VIBE_TEST_HANG_TIMEOUT];
    while (([again containsObjectForKey:@"old one"] || [again containsObjectForKey:@"old two"])
            && deadline.timeIntervalSinceNow > 0) {
        [NSThread sleepForTimeInterval:0.05];
    }
    XCTAssertFalse([again containsObjectForKey:@"old one"]);
    XCTAssertTrue([again containsObjectForKey:@"young"]);
    XCTAssertTrue([again containsObjectForKey:@"new"]);
    XCTAssertEqual(again.byteCount, VibeAllocatedBytes(again));
}

// Records on demand can't be turned off: nothing would read the records back.
- (void)testRecordsOnDemandIsOneWay {
    PINDiskCache *cache = [PINCache audioCacheWithName:@"one way" rootPath:_root].diskCache;
    XCTAssertThrows(cache.recordsOnDemand = NO);
    XCTAssertTrue(cache.recordsOnDemand);
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

#pragma mark - The lock

// An entry's file, found with no hit, which would re-date it.
static NSString *VibeEntryPath(PINDiskCache *cache, NSString *key) {
    return [cache.cacheURL URLByAppendingPathComponent:key isDirectory:NO].path;
}

// Runs work on another thread and reports whether it finished in time.
static BOOL VibeFinishesElsewhere(dispatch_block_t work) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        work();
        dispatch_semaphore_signal(done);
    });
    return dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC))) == 0;
}

// A hit and a miss take no lock, so they answer while a write holds it.
- (void)testAHitAndAMissAnswerWhileTheLockIsHeld {
    PINDiskCache *cache = [PINCache audioCacheWithName:@"unlocked hit" rootPath:_root].diskCache;
    VibeWaitForDiskState(cache);
    [cache setObject:[NSMutableData dataWithLength:3000] forKey:@"one"];
    __block NSData *hit = nil;
    __block id miss = @"unread";
    __block BOOL answered = NO;
    [cache synchronouslyLockFileAccessWhileExecutingBlock:^(PINDiskCache *locked) {
        answered = VibeFinishesElsewhere(^{
            hit = (NSData *)[cache objectForKey:@"one"];
            miss = [cache objectForKey:@"two"];
        });
    }];
    XCTAssertTrue(answered);
    XCTAssertEqual(hit.length, 3000u);
    XCTAssertNil(miss);
}

// A hit re-dates an entry last used over a day ago, from the dates of the
// file it read, and leaves one used since.
- (void)testAHitReDatesOnlyAnEntryADayOld {
    PINDiskCache *cache = [PINCache audioCacheWithName:@"re-date" rootPath:_root].diskCache;
    VibeWaitForDiskState(cache);
    NSDate *twoDays = [NSDate dateWithTimeIntervalSinceNow:-2 * 86400.0];
    NSDate *anHour = [NSDate dateWithTimeIntervalSinceNow:-3600.0];
    NSDictionary<NSString *, NSDate *> *used = @{@"old": twoDays, @"recent": anHour};
    for (NSString *key in used) {
        [cache setObject:[NSMutableData dataWithLength:100] forKey:key];
        XCTAssertTrue([NSFileManager.defaultManager setAttributes:@{NSFileModificationDate: used[key]}
                                                     ofItemAtPath:VibeEntryPath(cache, key) error:nil]);
        XCTAssertNotNil([cache objectForKey:key]);
    }
    // The re-date runs on the store's queue.
    NSDate *(^modified)(NSString *) = ^NSDate *(NSString *key) {
        return [NSFileManager.defaultManager attributesOfItemAtPath:VibeEntryPath(cache, key) error:nil].fileModificationDate;
    };
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:VIBE_TEST_HANG_TIMEOUT];
    while ([modified(@"old") timeIntervalSinceNow] < -60 && deadline.timeIntervalSinceNow > 0) {
        [NSThread sleepForTimeInterval:0.01];
    }
    XCTAssertGreaterThan([modified(@"old") timeIntervalSinceNow], -60);
    XCTAssertEqualWithAccuracy([modified(@"recent") timeIntervalSinceDate:anHour], 0, 1);
}

// Hits that race writes over their key and its removal each see a whole
// entry or none.
- (void)testAHitRacingWritesAndRemovalsSeesAWholeEntryOrNone {
    PINDiskCache *cache = [PINCache audioCacheWithName:@"racing hits" rootPath:_root].diskCache;
    VibeWaitForDiskState(cache);
    NSMutableData *small = [NSMutableData dataWithLength:1000];
    memset(small.mutableBytes, 0xaa, small.length);
    NSMutableData *large = [NSMutableData dataWithLength:30000];
    memset(large.mutableBytes, 0xbb, large.length);
    __block _Atomic(int) writing = 1;
    dispatch_group_t writers = dispatch_group_create();
    dispatch_group_async(writers, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        for (NSUInteger i = 0; writing; i++) {
            if (i % 3 == 2) {
                [cache removeObjectForKey:@"key"];
            } else {
                [cache setObject:(i % 3 ? large : small) forKey:@"key"];
            }
        }
    });
    NSUInteger whole = 0;
    for (NSUInteger i = 0; i < 2000; i++) {
        NSData *read = (NSData *)[cache objectForKey:@"key"];
        if (read) {
            XCTAssertTrue([read isEqualToData:small] || [read isEqualToData:large], @"a read of %lu bytes", (unsigned long)read.length);
            whole++;
        }
    }
    writing = 0;
    XCTAssertEqual(dispatch_group_wait(writers, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC))), 0);
    XCTAssertGreaterThan(whole, 0u);
    XCTAssertEqual(cache.byteCount, VibeAllocatedBytes(cache));
}

// A trim sorts its listing before it takes the lock. Writes and hits during
// it go on: each entry written meanwhile stays, as it was not listed, and the
// byte count still matches the files.
- (void)testATrimRacingWritesAndHitsKeepsTheirEntriesAndItsCount {
    PINDiskCache *cache = [PINCache audioCacheWithName:@"racing trim" rootPath:_root].diskCache;
    VibeWaitForDiskState(cache);
    for (NSUInteger i = 0; i < 400; i++) {
        NSString *key = [NSString stringWithFormat:@"listed %lu", (unsigned long)i];
        [cache setObject:[NSMutableData dataWithLength:5000] forKey:key];
        XCTAssertTrue([NSFileManager.defaultManager setAttributes:@{NSFileModificationDate: [NSDate dateWithTimeIntervalSinceNow:-86400.0 * 10 + i]}
                                                     ofItemAtPath:VibeEntryPath(cache, key) error:nil]);
    }
    NSUInteger target = cache.byteCount / 2;
    __block _Atomic(int) trimming = 1;
    __block NSUInteger written = 0;
    dispatch_group_t racers = dispatch_group_create();
    dispatch_group_async(racers, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        for (; trimming || written < 20; written++) {
            [cache setObject:[NSMutableData dataWithLength:5000] forKey:[NSString stringWithFormat:@"new %lu", (unsigned long)written]];
        }
    });
    dispatch_group_async(racers, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        for (NSUInteger i = 0; trimming; i++) {
            // The newer half, which a hit re-dates but the trim keeps anyway.
            (void)[cache objectForKey:[NSString stringWithFormat:@"listed %lu", (unsigned long)(200 + i % 200)]];
        }
    });
    [cache trimToSizeByEvictionStrategy:target];
    trimming = 0;
    XCTAssertEqual(dispatch_group_wait(racers, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC))), 0);
    for (NSUInteger i = 0; i < written; i++) {
        NSString *key = [NSString stringWithFormat:@"new %lu", (unsigned long)i];
        XCTAssertTrue([cache containsObjectForKey:key], @"%@", key);
    }
    XCTAssertFalse([cache containsObjectForKey:@"listed 0"], @"the least recently used went");
    XCTAssertEqual(cache.byteCount, VibeAllocatedBytes(cache));
}

// An enumeration, as the usage count runs, holds no lock while its block
// runs: a write and a hit from another thread answer meanwhile.
- (void)testAnEnumerationHoldsNoLockWhileItsBlockRuns {
    PINCache *store = [PINCache audioCacheWithName:@"unlocked usage" rootPath:_root];
    PINDiskCache *cache = store.diskCache;
    [cache setObject:[NSMutableData dataWithLength:1000] forKey:@"one"];
    [cache setObject:[NSMutableData dataWithLength:1000] forKey:@"two"];
    __block BOOL answered = NO;
    __block NSUInteger listed = 0;
    [cache enumerateObjectsWithBlock:^(NSString *key, NSURL *fileURL, BOOL *stop) {
        if (listed++ == 0) {
            answered = VibeFinishesElsewhere(^{
                [cache setObject:[NSMutableData dataWithLength:2000] forKey:@"three"];
                (void)[cache objectForKey:@"one"];
            });
        }
    }];
    XCTAssertTrue(answered);
    XCTAssertEqual(listed, 2u, @"the listing was made before the write");
    XCTestExpectation *counted = [self expectationWithDescription:@"counted"];
    [store audioDiskUsageWithCompletion:^(NSUInteger fileCount, unsigned long long totalBytes) {
        XCTAssertEqual(fileCount, 3u);
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
