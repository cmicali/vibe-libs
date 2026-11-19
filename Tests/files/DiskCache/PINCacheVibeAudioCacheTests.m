//
// The bounded disk cache: a store under a root of the caller's, with the
// shared byte and age limits, its usage on disk, and the removal of the
// stores other versions left.
//

#import <XCTest/XCTest.h>
#import <os/lock.h>
#import <stdatomic.h>

#import "PINCache+VibeAudioCache.h"

// A point a store's launch count stops at, through PINDiskCache's seam, until
// the test lets it go on. It stops every store of its name there once.
@interface VibeCountHold : NSObject
@property (nonatomic, readonly) NSString *name;
@property (nonatomic, readonly) VibePINDiskCacheCountStage stage;
@property (nonatomic, readonly, nullable) NSString *key;
@end

@implementation VibeCountHold {
    NSCondition *_condition;
    NSUInteger _held;
    BOOL _released;
    NSHashTable *_stopped;
}

- (instancetype)initWithName:(NSString *)name stage:(VibePINDiskCacheCountStage)stage key:(nullable NSString *)key {
    if ((self = [super init])) {
        _name = [name copy];
        _stage = stage;
        _key = [key copy];
        _condition = [[NSCondition alloc] init];
        _stopped = [NSHashTable weakObjectsHashTable];
    }
    return self;
}

- (void)stopCache:(PINDiskCache *)cache stage:(VibePINDiskCacheCountStage)stage key:(nullable NSString *)key {
    if (stage != _stage || ![cache.name isEqualToString:_name] || (_key && ![key isEqualToString:_key])) {
        return;
    }
    [_condition lock];
    if (![_stopped containsObject:cache]) {
        [_stopped addObject:cache];
        _held++;
        [_condition broadcast];
        // Twice the hang timeout, so a change that waits for the count
        // fails its own wait first.
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2 * VIBE_TEST_HANG_TIMEOUT];
        while (!_released && [_condition waitUntilDate:deadline]) {
        }
    }
    [_condition unlock];
}

- (BOOL)waitUntilHeld:(NSUInteger)count {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:VIBE_TEST_HANG_TIMEOUT];
    [_condition lock];
    while (_held < count && [_condition waitUntilDate:deadline]) {
    }
    BOOL held = _held >= count;
    [_condition unlock];
    return held;
}

- (void)letGo {
    [_condition lock];
    _released = YES;
    [_condition broadcast];
    [_condition unlock];
}

@end

static os_unfair_lock VibeHoldsLock = OS_UNFAIR_LOCK_INIT;
static NSMutableArray<VibeCountHold *> *VibeHolds;

static void VibeCountSeam(PINDiskCache *cache, VibePINDiskCacheCountStage stage, NSString *key) {
    os_unfair_lock_lock(&VibeHoldsLock);
    NSArray<VibeCountHold *> *holds = [VibeHolds copy];
    os_unfair_lock_unlock(&VibeHoldsLock);
    for (VibeCountHold *hold in holds) {
        [hold stopCache:cache stage:stage key:key];
    }
}

// A hold on the store's count at a stage, and at a key for a file's stage.
static VibeCountHold *VibeHoldCount(NSString *name, VibePINDiskCacheCountStage stage, NSString *key) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        VibeHolds = [NSMutableArray array];
        __atomic_store_n(&VibePINDiskCacheCountSeamFunction, &VibeCountSeam, __ATOMIC_RELEASE);
    });
    VibeCountHold *hold = [[VibeCountHold alloc] initWithName:name stage:stage key:key];
    os_unfair_lock_lock(&VibeHoldsLock);
    [VibeHolds addObject:hold];
    os_unfair_lock_unlock(&VibeHoldsLock);
    return hold;
}

static void VibeLetGoOfEveryCount(void) {
    os_unfair_lock_lock(&VibeHoldsLock);
    NSArray<VibeCountHold *> *holds = [VibeHolds copy];
    [VibeHolds removeAllObjects];
    os_unfair_lock_unlock(&VibeHoldsLock);
    for (VibeCountHold *hold in holds) {
        [hold letGo];
    }
}

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
    VibeLetGoOfEveryCount();
    [NSFileManager.defaultManager removeItemAtPath:_root error:nil];
    [super tearDown];
}

// A store has its limits as soon as it is made.
- (void)testAStoreUnderARootHasTheSharedLimits {
    PINCache *cache = [PINCache audioCacheWithName:@"limits" rootPath:_root];
    XCTAssertEqual(cache.diskCache.byteLimit, 1024u * 1024u * 1024u);
    XCTAssertEqual(cache.diskCache.ageLimit, 180.0 * 24 * 60 * 60);
    XCTAssertEqual(VibeAudioCacheDefaultByteLimit, 1024u * 1024u * 1024u);
    XCTAssertEqual(VibeAudioCacheDefaultAgeLimit, 180.0 * 24 * 60 * 60);
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

// An entry's file, found with no hit, which would re-date it.
static NSString *VibeEntryPath(PINDiskCache *cache, NSString *key) {
    return [cache.cacheURL URLByAppendingPathComponent:key isDirectory:NO].path;
}

// Waits until a hit's re-date, which runs on the store's queue, has moved
// the entry's date to now, and returns that date.
static NSDate *VibeWaitForReDate(PINDiskCache *cache, NSString *key) {
    NSDate *(^used)(void) = ^NSDate *(void) {
        return [NSFileManager.defaultManager attributesOfItemAtPath:VibeEntryPath(cache, key) error:nil].fileModificationDate;
    };
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:VIBE_TEST_HANG_TIMEOUT];
    while ([used() timeIntervalSinceNow] < -60 && deadline.timeIntervalSinceNow > 0) {
        [NSThread sleepForTimeInterval:0.01];
    }
    return used();
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

// A move renames the entry's file: the bytes follow it to the new key, and
// the count stays. It refuses a new key that holds an entry, an old key that
// holds none, and equal keys, and changes nothing then.
- (void)testAMoveRenamesTheEntryAndRefusesATakenKey {
    PINDiskCache *cache = [PINCache audioCacheWithName:@"move" rootPath:_root].diskCache;
    VibeWaitForDiskState(cache);
    NSData *one = [NSMutableData dataWithLength:1000];
    NSData *two = [NSMutableData dataWithLength:30000];
    [cache setObject:one forKey:@"one"];
    [cache setObject:two forKey:@"two"];
    NSUInteger bytes = cache.byteCount;
    XCTAssertTrue([cache moveObjectForKey:@"one" toKey:@"moved"]);
    XCTAssertNil([cache objectForKey:@"one"]);
    XCTAssertEqualObjects([cache objectForKey:@"moved"], one);
    XCTAssertEqual(cache.byteCount, bytes);
    XCTAssertEqual(cache.byteCount, VibeAllocatedBytes(cache));

    XCTAssertFalse([cache moveObjectForKey:@"moved" toKey:@"two"], @"a taken key");
    XCTAssertEqualObjects([cache objectForKey:@"moved"], one);
    XCTAssertEqualObjects([cache objectForKey:@"two"], two);
    XCTAssertFalse([cache moveObjectForKey:@"absent" toKey:@"other"], @"no entry");
    XCTAssertNil([cache objectForKey:@"other"]);
    XCTAssertFalse([cache moveObjectForKey:@"two" toKey:@"two"], @"equal keys");
    XCTAssertEqualObjects([cache objectForKey:@"two"], two);
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
- (void)testATrimToADateRemovesTheEntriesLastUsedBefore {
    PINDiskCache *first = [PINCache audioCacheWithName:@"dated" rootPath:_root].diskCache;
    VibeWaitForDiskState(first);
    [first setObject:[NSMutableData dataWithLength:1000] forKey:@"old"];
    [first setObject:[NSMutableData dataWithLength:1000] forKey:@"new"];
    XCTAssertTrue([NSFileManager.defaultManager setAttributes:@{NSFileModificationDate: [NSDate dateWithTimeIntervalSinceNow:-86400.0 * 100]}
                                                 ofItemAtPath:[first fileURLForKey:@"old"].path error:nil]);
    first = nil;
    PINDiskCache *cache = [PINCache audioCacheWithName:@"dated" rootPath:_root].diskCache;
    VibeWaitForDiskState(cache);
    [cache trimToDate:[NSDate dateWithTimeIntervalSinceNow:-86400.0 * 50]];
    XCTAssertFalse([cache containsObjectForKey:@"old"]);
    XCTAssertTrue([cache containsObjectForKey:@"new"]);
}

// A store that has seen no entry last used before a date lists nothing to
// trim to it: an entry made older behind its back stays, until a reopening reads
// its date and trims it.
- (void)testATrimToADateListsNothingWhenNothingIsThatOld {
    PINDiskCache *cache = [PINCache audioCacheWithName:@"recent" rootPath:_root].diskCache;
    VibeWaitForDiskState(cache);
    [cache setObject:[NSMutableData dataWithLength:1000] forKey:@"one"];
    XCTAssertTrue([NSFileManager.defaultManager setAttributes:@{NSFileModificationDate: [NSDate dateWithTimeIntervalSinceNow:-86400.0 * 100]}
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

// The age limit counts from an entry's last use, never from its write: an
// entry written long ago and read since stays, and one nobody read goes.
- (void)testAnEntryReadSinceItsWriteDoesNotAgeOut {
    PINDiskCache *first = [PINCache audioCacheWithName:@"read since" rootPath:_root].diskCache;
    VibeWaitForDiskState(first);
    for (NSString *key in @[@"read", @"unread"]) {
        [first setObject:[NSMutableData dataWithLength:1000] forKey:key];
        // The creation date first, since a modification date before it
        // moves it back too.
        XCTAssertTrue([NSFileManager.defaultManager setAttributes:@{NSFileCreationDate: [NSDate dateWithTimeIntervalSinceNow:-86400.0 * 300]}
                                                     ofItemAtPath:VibeEntryPath(first, key) error:nil]);
    }
    XCTAssertTrue([NSFileManager.defaultManager setAttributes:@{NSFileModificationDate: [NSDate dateWithTimeIntervalSinceNow:-86400.0 * 10]}
                                                 ofItemAtPath:VibeEntryPath(first, @"read") error:nil]);
    XCTAssertTrue([NSFileManager.defaultManager setAttributes:@{NSFileModificationDate: [NSDate dateWithTimeIntervalSinceNow:-86400.0 * 250]}
                                                 ofItemAtPath:VibeEntryPath(first, @"unread") error:nil]);
    first = nil;
    PINDiskCache *cache = [PINCache audioCacheWithName:@"read since" rootPath:_root].diskCache;
    VibeWaitForDiskState(cache);
    [cache trimToDate:[NSDate dateWithTimeIntervalSinceNow:-86400.0 * 180]];
    XCTAssertTrue([cache containsObjectForKey:@"read"]);
    XCTAssertFalse([cache containsObjectForKey:@"unread"]);
    XCTAssertEqual(cache.byteCount, VibeAllocatedBytes(cache));
}

// A hit is a use: it re-dates an old entry, so the next launch's age trim
// keeps it, and removes the entry nobody read.
- (void)testAHitKeepsAnOldEntryFromAgingOut {
    PINDiskCache *cache = [PINCache audioCacheWithName:@"hit keeps" rootPath:_root].diskCache;
    VibeWaitForDiskState(cache);
    for (NSString *key in @[@"hit", @"missed"]) {
        [cache setObject:[NSMutableData dataWithLength:1000] forKey:key];
        XCTAssertTrue([NSFileManager.defaultManager setAttributes:@{NSFileModificationDate: [NSDate dateWithTimeIntervalSinceNow:-86400.0 * 200]}
                                                     ofItemAtPath:VibeEntryPath(cache, key) error:nil]);
    }
    XCTAssertNotNil([cache objectForKey:@"hit"]);
    XCTAssertGreaterThan([VibeWaitForReDate(cache, @"hit") timeIntervalSinceNow], -60);
    cache = nil;
    PINDiskCache *again = [PINCache audioCacheWithName:@"hit keeps" rootPath:_root].diskCache;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:VIBE_TEST_HANG_TIMEOUT];
    while ([again containsObjectForKey:@"missed"] && deadline.timeIntervalSinceNow > 0) {
        [NSThread sleepForTimeInterval:0.05];
    }
    XCTAssertFalse([again containsObjectForKey:@"missed"]);
    XCTAssertTrue([again containsObjectForKey:@"hit"]);
}

// A limit is set at once, so the latest wins, whatever order the store's
// concurrent queue runs the setters' trims in.
- (void)testTheLatestLimitWinsAtOnce {
    PINDiskCache *cache = [PINCache audioCacheWithName:@"latest" rootPath:_root].diskCache;
    cache.byteLimit = 2 * 1024 * 1024;
    cache.ageLimit = 86400.0;
    XCTAssertEqual(cache.byteLimit, 2u * 1024 * 1024);
    XCTAssertEqual(cache.ageLimit, 86400.0);
    VibeWaitForDiskState(cache);
    XCTAssertEqual(cache.byteLimit, 2u * 1024 * 1024, @"no earlier setter's operation sets it back");
    XCTAssertEqual(cache.ageLimit, 86400.0);
}

// A plain store that read its records before the mode keeps their dates in
// the bound the mode drops them for, so an old one is still trimmed.
- (void)testRecordsDroppedForTheModeKeepTheirDates {
    PINDiskCache *first = [[PINCache alloc] initWithName:@"dropped" rootPath:_root].diskCache;
    VibeWaitForDiskState(first);
    [first setObject:[NSMutableData dataWithLength:1000] forKey:@"old"];
    XCTAssertTrue([NSFileManager.defaultManager setAttributes:@{NSFileModificationDate: [NSDate dateWithTimeIntervalSinceNow:-86400.0 * 100]}
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
        XCTAssertTrue([NSFileManager.defaultManager setAttributes:@{NSFileModificationDate: made}
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
    XCTAssertGreaterThan([VibeWaitForReDate(cache, @"old") timeIntervalSinceNow], -60);
    XCTAssertEqualWithAccuracy([[NSFileManager.defaultManager attributesOfItemAtPath:VibeEntryPath(cache, @"recent") error:nil].fileModificationDate
                                   timeIntervalSinceDate:anHour], 0, 1);
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
// it go on: each entry written meanwhile stays, as it was not listed. A listed
// entry written again before its removal stays too, as its file is newer than
// the listing's. The byte count still matches the files.
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
    __block _Atomic(NSUInteger) written = 0;
    // The trim's first removal, of the oldest, waits for a write of a new
    // key, and writes again the next oldest, which the trim listed.
    __block _Atomic(int) removals = 0;
    __weak PINDiskCache *weakCache = cache;
    cache.willRemoveObjectBlock = ^(PINDiskCache *removing, NSString *key, id<NSCoding> object) {
        if (atomic_fetch_add(&removals, 1) != 0) {
            return;
        }
        NSUInteger seen = written;
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:VIBE_TEST_HANG_TIMEOUT];
        while (written == seen && deadline.timeIntervalSinceNow > 0) {
            [NSThread sleepForTimeInterval:0.001];
        }
        [weakCache setObject:[NSMutableData dataWithLength:7000] forKey:@"listed 1"];
    };
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:VIBE_TEST_HANG_TIMEOUT];
    while (!cache.willRemoveObjectBlock && deadline.timeIntervalSinceNow > 0) {
        [NSThread sleepForTimeInterval:0.01];
    }
    dispatch_group_t racers = dispatch_group_create();
    dispatch_group_async(racers, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        while (trimming || written < 20) {
            NSUInteger next = written;
            [cache setObject:[NSMutableData dataWithLength:5000] forKey:[NSString stringWithFormat:@"new %lu", (unsigned long)next]];
            written = next + 1;
        }
    });
    dispatch_group_async(racers, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        for (NSUInteger i = 0; trimming; i++) {
            // The newer half, which a hit re-dates but the trim keeps anyway.
            (void)[cache objectForKey:[NSString stringWithFormat:@"listed %lu", (unsigned long)(200 + i % 200)]];
        }
    });
    NSUInteger before = written;
    [cache trimToSizeByEvictionStrategy:target];
    NSUInteger during = written - before;
    trimming = 0;
    XCTAssertEqual(dispatch_group_wait(racers, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC))), 0);
    XCTAssertGreaterThan(during, 0u, @"a write landed during the trim");
    XCTAssertGreaterThan((NSUInteger)removals, 1u);
    NSUInteger total = written;
    for (NSUInteger i = 0; i < total; i++) {
        NSString *key = [NSString stringWithFormat:@"new %lu", (unsigned long)i];
        XCTAssertTrue([cache containsObjectForKey:key], @"%@", key);
    }
    XCTAssertFalse([cache containsObjectForKey:@"listed 0"], @"the least recently used went");
    XCTAssertFalse([cache containsObjectForKey:@"listed 2"]);
    XCTAssertEqual([(NSData *)[cache objectForKey:@"listed 1"] length], 7000u, @"written again, it stayed");
    XCTAssertEqual(cache.byteCount, VibeAllocatedBytes(cache));
}

// A file that won't decode is removed as any entry is, so the byte count
// follows it.
- (void)testAnEntryThatWontDecodeGoesWithItsBytes {
    PINDiskCache *cache = [[PINDiskCache alloc] initWithName:@"undecodable" rootPath:_root
                                                  serializer:^NSData *(id<NSCoding> object, NSString *key) {
        return (NSData *)object;
    }
                                                deserializer:^id<NSCoding>(NSData *data, NSString *key) {
        if ([key isEqualToString:@"bad"]) {
            @throw [NSException exceptionWithName:NSInvalidArchiveOperationException reason:@"won't decode" userInfo:nil];
        }
        return data;
    }];
    cache.recordsOnDemand = YES;
    VibeWaitForDiskState(cache);
    [cache setObject:[NSMutableData dataWithLength:1000] forKey:@"good"];
    [cache setObject:[NSMutableData dataWithLength:1000] forKey:@"bad"];
    XCTAssertEqual(cache.byteCount, VibeAllocatedBytes(cache));
    // A Debug build asserts after the removal, so the read may throw.
    @try {
        (void)[cache objectForKey:@"bad"];
    } @catch (NSException *exception) {
    }
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:VibeEntryPath(cache, @"bad")]);
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:VibeEntryPath(cache, @"good")]);
    XCTAssertEqual(cache.byteCount, VibeAllocatedBytes(cache));
    XCTAssertGreaterThan(cache.byteCount, 0u);
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

#pragma mark - Changes during the launch's count

// A store of entries k0 to k9, each 10,000 bytes, closed, for a store opened
// again over it to count.
- (void)makeStoreOfTenEntries:(NSString *)name {
    PINDiskCache *first = [PINCache audioCacheWithName:name rootPath:_root].diskCache;
    VibeWaitForDiskState(first);
    for (NSUInteger i = 0; i < 10; i++) {
        [first setObject:[NSMutableData dataWithLength:10000] forKey:[NSString stringWithFormat:@"k%lu", (unsigned long)i]];
    }
}

// Once the count is done, the byte count is the files' bytes, and a store
// opened fresh over them counts the same.
- (void)assertSettled:(PINDiskCache *)cache {
    VibeWaitForDiskState(cache);
    XCTAssertEqual(cache.byteCount, VibeAllocatedBytes(cache));
    PINDiskCache *fresh = [PINCache audioCacheWithName:cache.name rootPath:_root].diskCache;
    VibeWaitForDiskState(fresh);
    XCTAssertEqual(fresh.byteCount, cache.byteCount);
}

// A write, a removal, a move, and a hit answer while the launch's count is
// held, where a write and a removal once waited for it.
- (void)testChangesAnswerWhileTheCountIsHeld {
    [self makeStoreOfTenEntries:@"held"];
    VibeCountHold *hold = VibeHoldCount(@"held", VibePINDiskCacheCountStageStart, nil);
    PINCache *store = [PINCache audioCacheWithName:@"held" rootPath:_root];
    PINDiskCache *cache = store.diskCache;
    XCTAssertTrue([hold waitUntilHeld:1]);
    __block NSData *hit = nil;
    BOOL answered = VibeFinishesElsewhere(^{
        [cache setObject:[NSMutableData dataWithLength:30000] forKey:@"new"];
        [cache setObject:[NSMutableData dataWithLength:30000] forKey:@"k1"];
        [cache removeObjectForKey:@"k2"];
        [cache moveObjectForKey:@"k3" toKey:@"moved"];
        hit = (NSData *)[cache objectForKey:@"k4"];
    });
    XCTAssertTrue(answered, @"a change waited for the count");
    XCTAssertEqual(hit.length, 10000u);
    VibeLetGoOfEveryCount();
    [self assertSettled:cache];
    XCTAssertNil([cache objectForKey:@"k2"]);
    XCTAssertEqual([(NSData *)[cache objectForKey:@"moved"] length], 10000u);
    XCTestExpectation *counted = [self expectationWithDescription:@"counted"];
    [store audioDiskUsageWithCompletion:^(NSUInteger fileCount, unsigned long long totalBytes) {
        XCTAssertEqual(fileCount, 10u);
        [counted fulfill];
    }];
    [self waitForExpectations:@[counted] timeout:VIBE_TEST_HANG_TIMEOUT];
}

// Changes made before the count lists the store, to files it then lists. The
// count must skip each such file: else a new key's bytes count twice, and an
// overwritten key's new size counts twice too, since the old size it replaced
// was never counted. One new key's file name is percent-encoded, as the count
// and a change must name a file alike.
- (void)testANewKeyWrittenBeforeTheCountListsItIsSkippedByTheCount {
    [self makeStoreOfTenEntries:@"new before"];
    VibeCountHold *hold = VibeHoldCount(@"new before", VibePINDiskCacheCountStageStart, nil);
    PINDiskCache *cache = [PINCache audioCacheWithName:@"new before" rootPath:_root].diskCache;
    XCTAssertTrue([hold waitUntilHeld:1]);
    [cache setObject:[NSMutableData dataWithLength:20000] forKey:@"new"];
    [cache setObject:[NSMutableData dataWithLength:30000] forKey:@"a key: 50%/b"];
    VibeLetGoOfEveryCount();
    [self assertSettled:cache];
}

- (void)testAKeyOverwrittenBeforeTheCountListsItIsSkippedByTheCount {
    [self makeStoreOfTenEntries:@"overwritten before"];
    VibeCountHold *hold = VibeHoldCount(@"overwritten before", VibePINDiskCacheCountStageStart, nil);
    PINDiskCache *cache = [PINCache audioCacheWithName:@"overwritten before" rootPath:_root].diskCache;
    XCTAssertTrue([hold waitUntilHeld:1]);
    [cache setObject:[NSMutableData dataWithLength:90000] forKey:@"k5"];
    VibeLetGoOfEveryCount();
    [self assertSettled:cache];
    XCTAssertEqual([(NSData *)[cache objectForKey:@"k5"] length], 90000u);
}

// A move before the count lists the store: the count meets only the new name,
// and the bytes go with the file.
- (void)testAMoveBeforeTheCountListsItsNewNameKeepsItsBytes {
    [self makeStoreOfTenEntries:@"moved before"];
    VibeCountHold *hold = VibeHoldCount(@"moved before", VibePINDiskCacheCountStageStart, nil);
    PINDiskCache *cache = [PINCache audioCacheWithName:@"moved before" rootPath:_root].diskCache;
    XCTAssertTrue([hold waitUntilHeld:1]);
    XCTAssertTrue([cache moveObjectForKey:@"k3" toKey:@"m3"]);
    VibeLetGoOfEveryCount();
    [self assertSettled:cache];
    XCTAssertEqual([(NSData *)[cache objectForKey:@"m3"] length], 10000u);
}

// Keys written after the count listed them, before it counts them, leave the
// right total, as their listed sizes are the old files'. One key's file name
// is percent-encoded.
- (void)testAKeyWrittenAfterTheCountListedItLeavesTheRightTotal {
    [self makeStoreOfTenEntries:@"met"];
    NSString *encoded = @"a key: 50%/b";
    PINDiskCache *first = [PINCache audioCacheWithName:@"met" rootPath:_root].diskCache;
    [first setObject:[NSMutableData dataWithLength:10000] forKey:encoded];
    VibeWaitForDiskState(first);
    first = nil;
    VibeCountHold *hold = VibeHoldCount(@"met", VibePINDiskCacheCountStageFile, encoded);
    PINDiskCache *cache = [PINCache audioCacheWithName:@"met" rootPath:_root].diskCache;
    XCTAssertTrue([hold waitUntilHeld:1]);
    [cache setObject:[NSMutableData dataWithLength:90000] forKey:@"k5"];
    [cache setObject:[NSMutableData dataWithLength:90000] forKey:encoded];
    XCTAssertEqual([(NSData *)[cache objectForKey:encoded] length], 90000u);
    [cache setObject:[NSMutableData dataWithLength:20000] forKey:@"new"];
    VibeLetGoOfEveryCount();
    [self assertSettled:cache];
    XCTAssertEqual([(NSData *)[cache objectForKey:@"k5"] length], 90000u);
}

// A key removed before the count reaches it, whether listed already or not,
// and one removed after, each leave the bytes of the files left.
- (void)testAKeyRemovedBeforeTheCountReachesIt {
    [self makeStoreOfTenEntries:@"removed before"];
    VibeCountHold *hold = VibeHoldCount(@"removed before", VibePINDiskCacheCountStageFile, @"k5");
    PINDiskCache *cache = [PINCache audioCacheWithName:@"removed before" rootPath:_root].diskCache;
    XCTAssertTrue([hold waitUntilHeld:1]);
    [cache removeObjectForKey:@"k5"];
    VibeLetGoOfEveryCount();
    [self assertSettled:cache];
    XCTAssertFalse([cache containsObjectForKey:@"k5"]);
}

- (void)testAKeyRemovedBeforeTheCountListsIt {
    [self makeStoreOfTenEntries:@"removed unlisted"];
    VibeCountHold *hold = VibeHoldCount(@"removed unlisted", VibePINDiskCacheCountStageStart, nil);
    PINDiskCache *cache = [PINCache audioCacheWithName:@"removed unlisted" rootPath:_root].diskCache;
    XCTAssertTrue([hold waitUntilHeld:1]);
    [cache removeObjectForKey:@"k5"];
    [cache removeObjectForKey:@"k6"];
    VibeLetGoOfEveryCount();
    [self assertSettled:cache];
}

- (void)testAKeyRemovedAfterTheCountReachedIt {
    [self makeStoreOfTenEntries:@"removed after"];
    VibeCountHold *hold = VibeHoldCount(@"removed after", VibePINDiskCacheCountStageEnd, nil);
    PINDiskCache *cache = [PINCache audioCacheWithName:@"removed after" rootPath:_root].diskCache;
    XCTAssertTrue([hold waitUntilHeld:1]);
    [cache removeObjectForKey:@"k5"];
    [cache setObject:[NSMutableData dataWithLength:30000] forKey:@"k6"];
    XCTAssertEqual(cache.byteCount, VibeAllocatedBytes(cache), @"the count had every file");
    VibeLetGoOfEveryCount();
    [self assertSettled:cache];
}

// A write that takes the store over its limit during the count fires a trim,
// which waits for the count, then cuts the store under the limit.
- (void)testATrimFiredDuringTheCountCutsOnceItIsDone {
    [self makeStoreOfTenEntries:@"trimmed"];
    VibeCountHold *hold = VibeHoldCount(@"trimmed", VibePINDiskCacheCountStageEnd, nil);
    PINDiskCache *cache = [PINCache audioCacheWithName:@"trimmed" rootPath:_root].diskCache;
    XCTAssertTrue([hold waitUntilHeld:1]);
    NSUInteger limit = VibeAllocatedBytes(cache) / 2;
    cache.byteLimit = limit;
    XCTAssertEqual(cache.byteLimit, limit);
    [cache setObject:[NSMutableData dataWithLength:10000] forKey:@"new"];
    VibeLetGoOfEveryCount();
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:VIBE_TEST_HANG_TIMEOUT];
    while (cache.byteCount > limit && deadline.timeIntervalSinceNow > 0) {
        [NSThread sleepForTimeInterval:0.01];
    }
    XCTAssertLessThanOrEqual(cache.byteCount, limit);
    XCTAssertTrue([cache containsObjectForKey:@"new"], @"the newest stayed");
    [self assertSettled:cache];
}

// An old entry moved before the count lists the store still ages out. The
// count skips its new name, so the move itself lowers the date the age
// limit's trim reads.
- (void)testAnOldEntryMovedDuringTheCountStillAgesOut {
    [self makeStoreOfTenEntries:@"aged move"];
    // With no store open, whose age limit's trim would remove it first.
    NSString *k0 = [[_root stringByAppendingPathComponent:[PINDiskCachePrefix stringByAppendingString:@".aged move"]]
                    stringByAppendingPathComponent:@"k0"];
    XCTAssertTrue([NSFileManager.defaultManager setAttributes:@{NSFileModificationDate: [NSDate dateWithTimeIntervalSinceNow:-86400.0 * 200]}
                                                 ofItemAtPath:k0 error:nil]);
    VibeCountHold *hold = VibeHoldCount(@"aged move", VibePINDiskCacheCountStageStart, nil);
    PINDiskCache *cache = [PINCache audioCacheWithName:@"aged move" rootPath:_root].diskCache;
    XCTAssertTrue([hold waitUntilHeld:1]);
    XCTAssertTrue([cache moveObjectForKey:@"k0" toKey:@"old"]);
    VibeLetGoOfEveryCount();
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:VIBE_TEST_HANG_TIMEOUT];
    while ([cache containsObjectForKey:@"old"] && deadline.timeIntervalSinceNow > 0) {
        [NSThread sleepForTimeInterval:0.05];
    }
    XCTAssertFalse([cache containsObjectForKey:@"old"]);
    XCTAssertTrue([cache containsObjectForKey:@"k1"]);
    [self assertSettled:cache];
}

// Moves during the count, as Metadata's after a tag rewrite: one listed but
// not counted, one counted, and one refused, keep the bytes with the files.
- (void)testMovesDuringTheCountKeepTheirBytes {
    [self makeStoreOfTenEntries:@"moves"];
    VibeCountHold *listed = VibeHoldCount(@"moves", VibePINDiskCacheCountStageFile, @"k5");
    PINDiskCache *cache = [PINCache audioCacheWithName:@"moves" rootPath:_root].diskCache;
    XCTAssertTrue([listed waitUntilHeld:1]);
    VibeCountHold *end = VibeHoldCount(@"moves", VibePINDiskCacheCountStageEnd, nil);
    XCTAssertTrue([cache moveObjectForKey:@"k5" toKey:@"m5"]);
    XCTAssertFalse([cache moveObjectForKey:@"k3" toKey:@"k4"], @"a taken key");
    [cache removeObjectForKey:@"k7"];
    [listed letGo];
    XCTAssertTrue([end waitUntilHeld:1]);
    XCTAssertTrue([cache moveObjectForKey:@"k0" toKey:@"m0"]);
    VibeLetGoOfEveryCount();
    [self assertSettled:cache];
    XCTAssertEqual([(NSData *)[cache objectForKey:@"m5"] length], 10000u);
    XCTAssertEqual([(NSData *)[cache objectForKey:@"m0"] length], 10000u);
}

// Two stores on one folder, each changed while both counts are held before
// they list it, each count the files the other left.
- (void)testTwoStoresOnOneFolderEachCountTheOthersFiles {
    [self makeStoreOfTenEntries:@"shared"];
    VibeCountHold *hold = VibeHoldCount(@"shared", VibePINDiskCacheCountStageStart, nil);
    PINDiskCache *one = [PINCache audioCacheWithName:@"shared" rootPath:_root].diskCache;
    PINDiskCache *two = [PINCache audioCacheWithName:@"shared" rootPath:_root].diskCache;
    XCTAssertTrue([hold waitUntilHeld:2]);
    [one setObject:[NSMutableData dataWithLength:20000] forKey:@"one"];
    [one removeObjectForKey:@"k1"];
    [two setObject:[NSMutableData dataWithLength:30000] forKey:@"two"];
    [two removeObjectForKey:@"k2"];
    VibeLetGoOfEveryCount();
    [self assertSettled:one];
    [self assertSettled:two];
}

// Removing every entry during the count stops it: the files it would list
// are gone, and a write after counts once.
- (void)testRemovingEveryEntryDuringTheCountStopsIt {
    [self makeStoreOfTenEntries:@"wiped during"];
    VibeCountHold *hold = VibeHoldCount(@"wiped during", VibePINDiskCacheCountStageFile, nil);
    PINDiskCache *cache = [PINCache audioCacheWithName:@"wiped during" rootPath:_root].diskCache;
    XCTAssertTrue([hold waitUntilHeld:1]);
    [cache removeAllObjects];
    [cache setObject:[NSMutableData dataWithLength:20000] forKey:@"new"];
    VibeLetGoOfEveryCount();
    [self assertSettled:cache];
    XCTAssertTrue([cache containsObjectForKey:@"new"]);
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

// Two kept names of one family both stay, as a store and the older one it
// imports do, and the family's other versions go.
- (void)testKeepsEveryCurrentNameOfOneFamily {
    NSArray<NSString *> *kept = @[@"com.pinterest.PINDiskCache.Audio Track Metadata",
                                  @"com.pinterest.PINDiskCache.Audio Track Metadata v11"];
    [self makeStores:[kept arrayByAddingObject:@"com.pinterest.PINDiskCache.Audio Track Metadata v10"]];

    [self removeOtherVersionsKeeping:@[@"Audio Track Metadata", @"Audio Track Metadata v11"] under:_root];

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
