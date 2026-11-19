//
// The SQLite store: writes, replacements, removals, moves, trims by use, the
// age limit from the last use, a reopening, a database that will not open, a
// crash between a file's write and its row, formats, and shared items.
//

#import <XCTest/XCTest.h>

#import "VibeCacheStore.h"
#import "VibeCacheStore+Testing.h"

@interface VibeCacheStoreTests : XCTestCase
@property (nonatomic, copy) NSString *directory;
@property (nonatomic, strong, nullable) VibeCacheStore *store;
@end

static NSData *VibeTestData(NSUInteger length, uint8_t seed) {
    NSMutableData *data = [NSMutableData dataWithLength:length];
    uint8_t *bytes = data.mutableBytes;
    for (NSUInteger i = 0; i < length; i++) {
        bytes[i] = (uint8_t)(seed + i);
    }
    return data;
}

static NSString *VibeTestKey(NSUInteger i) {
    return [NSString stringWithFormat:@"k%lu", (unsigned long)i];
}

@implementation VibeCacheStoreTests

- (void)setUp {
    [super setUp];
    self.directory = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"VibeCacheStoreTests-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    self.store = [self openStore];
    XCTAssertNotNil(self.store);
}

- (void)tearDown {
    [self.store close];
    self.store = nil;
    [NSFileManager.defaultManager removeItemAtPath:self.directory error:NULL];
    [super tearDown];
}

- (nullable VibeCacheStore *)openStore {
    return [[VibeCacheStore alloc] initWithDirectory:self.directory];
}

- (void)reopen {
    [self.store close];
    self.store = [self openStore];
    XCTAssertNotNil(self.store);
}

- (void)waitForQueue {
    XCTestExpectation *done = [self expectationWithDescription:@"queue"];
    [self.store performAfterQueuedWork:^{
        [done fulfill];
    }];
    [self waitForExpectations:@[done] timeout:VIBE_TEST_HANG_TIMEOUT];
}

- (void)maintain {
    XCTestExpectation *done = [self expectationWithDescription:@"maintenance"];
    [self.store performMaintenanceWithCompletion:^{
        [done fulfill];
    }];
    [self waitForExpectations:@[done] timeout:VIBE_TEST_HANG_TIMEOUT];
}

- (NSString *)filesPath {
    return [self.directory stringByAppendingPathComponent:@"Files"];
}

// MARK: Writes and reads

- (void)testWritesReadBackInARowAndInAFile {
    NSData *small = VibeTestData(900, 1);
    NSData *large = VibeTestData(200 * 1024, 2);
    [self.store setData:small forKey:@"small" format:3 sharedName:nil];
    [self.store setData:large forKey:@"large" format:3 sharedName:@"picture"];

    VibeCacheHit *hit = [self.store hitForKey:@"small" format:3];
    XCTAssertEqualObjects(hit.data, small);
    XCTAssertEqual(hit.format, 3);
    XCTAssertFalse(hit.older);
    XCTAssertNil(hit.sharedName);
    hit = [self.store hitForKey:@"large" format:3];
    XCTAssertEqualObjects(hit.data, large);
    XCTAssertEqualObjects(hit.sharedName, @"picture");
    XCTAssertNil([self.store hitForKey:@"missing" format:3]);
    XCTAssertTrue([self.store hasEntryForKey:@"large"]);
    XCTAssertFalse([self.store hasEntryForKey:@"missing"]);

    XCTAssertEqual(self.store.fileNamesForTesting.count, 1u);
    VibeCacheUsage usage = self.store.usage;
    XCTAssertEqual(usage.entries, 2u);
    XCTAssertEqual(usage.bytes, small.length + large.length);
}

- (void)testAnEmptyBlobReadsBack {
    [self.store setData:[NSData data] forKey:@"empty" format:1 sharedName:nil];
    VibeCacheHit *hit = [self.store hitForKey:@"empty" format:1];
    XCTAssertNotNil(hit);
    XCTAssertEqual(hit.data.length, 0u);
}

- (void)testAReplacementRemovesTheOldFileAndCountsTheNewSize {
    [self.store setData:VibeTestData(100 * 1024, 1) forKey:@"k" format:1 sharedName:nil];
    NSArray *first = self.store.fileNamesForTesting;
    XCTAssertEqual(first.count, 1u);

    NSData *second = VibeTestData(120 * 1024, 2);
    [self.store setData:second forKey:@"k" format:1 sharedName:nil];
    NSArray *now = self.store.fileNamesForTesting;
    XCTAssertEqual(now.count, 1u);
    XCTAssertNotEqualObjects(now, first);
    XCTAssertEqualObjects([self.store hitForKey:@"k" format:1].data, second);

    NSData *inlined = VibeTestData(500, 3);
    [self.store setData:inlined forKey:@"k" format:1 sharedName:nil];
    XCTAssertEqual(self.store.fileNamesForTesting.count, 0u);
    XCTAssertEqualObjects([self.store hitForKey:@"k" format:1].data, inlined);
    XCTAssertEqual(self.store.usage.entries, 1u);
    XCTAssertEqual(self.store.usage.bytes, 500u);
}

- (void)testARemovalTakesTheRowAndItsFile {
    [self.store setData:VibeTestData(100 * 1024, 1) forKey:@"large" format:1 sharedName:nil];
    [self.store setData:VibeTestData(10, 1) forKey:@"small" format:1 sharedName:nil];
    [self.store removeEntryForKey:@"large"];
    [self.store removeEntryForKey:@"missing"];
    XCTAssertNil([self.store hitForKey:@"large" format:1]);
    XCTAssertEqual(self.store.fileNamesForTesting.count, 0u);
    XCTAssertEqual(self.store.usage.entries, 1u);
    XCTAssertEqual(self.store.usage.bytes, 10u);
}

- (void)testAMoveCarriesTheEntryAndReplacesOneThere {
    NSData *moved = VibeTestData(100 * 1024, 1);
    [self.store setData:moved forKey:@"old" format:1 sharedName:@"a"];
    [self.store setData:VibeTestData(90 * 1024, 2) forKey:@"new" format:1 sharedName:@"b"];
    [self.store setSharedData:VibeTestData(10, 1) forName:@"b" part:@"thumb" format:1];

    XCTAssertTrue([self.store moveEntryFromKey:@"old" toKey:@"new"]);
    XCTAssertNil([self.store hitForKey:@"old" format:1]);
    VibeCacheHit *hit = [self.store hitForKey:@"new" format:1];
    XCTAssertEqualObjects(hit.data, moved);
    XCTAssertEqualObjects(hit.sharedName, @"a");
    // The replaced entry's file goes, and the shared item only it named.
    XCTAssertEqual(self.store.fileNamesForTesting.count, 1u);
    XCTAssertFalse([self.store hasSharedItemForName:@"b" part:@"thumb"]);
    XCTAssertEqual(self.store.usage.entries, 1u);
    XCTAssertEqual(self.store.usage.bytes, moved.length);

    XCTAssertFalse([self.store moveEntryFromKey:@"missing" toKey:@"other"]);
    XCTAssertTrue([self.store hasEntryForKey:@"new"]);
}

- (void)testRemovingEverythingEmptiesTheStore {
    for (NSUInteger i = 0; i < 20; i++) {
        [self.store setData:VibeTestData(i % 2 ? 100 * 1024 : 100, (uint8_t)i)
                     forKey:VibeTestKey(i) format:1 sharedName:@"p"];
    }
    [self.store setSharedData:VibeTestData(10, 1) forName:@"p" part:@"thumb" format:1];
    XCTestExpectation *done = [self expectationWithDescription:@"removed"];
    [self.store removeAllWithCompletion:^{
        [done fulfill];
    }];
    [self waitForExpectations:@[done] timeout:VIBE_TEST_HANG_TIMEOUT];
    VibeCacheUsage usage = self.store.usage;
    XCTAssertEqual(usage.entries, 0u);
    XCTAssertEqual(usage.sharedItems, 0u);
    XCTAssertEqual(usage.bytes, 0u);
    XCTAssertEqual(self.store.fileNamesForTesting.count, 0u);
    XCTAssertNil([self.store hitForKey:@"k0" format:1]);

    [self.store setData:VibeTestData(10, 1) forKey:@"after" format:1 sharedName:nil];
    XCTAssertNotNil([self.store hitForKey:@"after" format:1]);
}

- (void)testTheUsageCompletionRunsOnMain {
    [self.store setData:VibeTestData(10, 1) forKey:@"k" format:1 sharedName:nil];
    XCTestExpectation *done = [self expectationWithDescription:@"usage"];
    [self.store usageWithCompletion:^(VibeCacheUsage usage) {
        XCTAssertTrue(NSThread.isMainThread);
        XCTAssertEqual(usage.entries, 1u);
        XCTAssertEqual(usage.bytes, 10u);
        [done fulfill];
    }];
    [self waitForExpectations:@[done] timeout:VIBE_TEST_HANG_TIMEOUT];
}

// MARK: Limits

- (void)testATrimTakesTheLeastRecentlyUsedFirst {
    self.store.byteLimit = 10000;
    for (NSUInteger i = 0; i < 10; i++) {
        [self.store setData:VibeTestData(1000, (uint8_t)i)
                     forKey:VibeTestKey(i) format:1 sharedName:nil];
    }
    [self waitForQueue];
    XCTAssertEqual(self.store.usage.entries, 10u);

    [self.store setDayOffsetForTesting:1];
    for (NSUInteger i = 0; i < 5; i++) {
        XCTAssertNotNil([self.store hitForKey:VibeTestKey(i) format:1]);
    }
    [self.store recordUsesNowForTesting];
    [self.store setData:VibeTestData(1000, 10) forKey:@"k10" format:1 sharedName:nil];
    [self waitForQueue];

    // 11,000 bytes over a limit of 10,000 cut to 9,000: the two oldest unread.
    XCTAssertEqual(self.store.usage.bytes, 9000u);
    XCTAssertFalse([self.store hasEntryForKey:@"k5"]);
    XCTAssertFalse([self.store hasEntryForKey:@"k6"]);
    for (NSString *key in @[@"k0", @"k1", @"k2", @"k3", @"k4", @"k7", @"k8", @"k9", @"k10"]) {
        XCTAssertTrue([self.store hasEntryForKey:key], @"%@", key);
    }
}

- (void)testATrimTakesSharedItemsByUseToo {
    self.store.byteLimit = 10000;
    [self.store setSharedData:VibeTestData(4000, 1) forName:@"old" part:@"thumb" format:1];
    [self.store setData:VibeTestData(100, 1) forKey:@"names-old" format:1 sharedName:@"old"];
    [self.store setDayOffsetForTesting:1];
    XCTAssertNotNil([self.store hitForKey:@"names-old" format:1]);
    [self.store recordUsesNowForTesting];
    [self.store setSharedData:VibeTestData(4000, 2) forName:@"new" part:@"thumb" format:1];
    [self.store setData:VibeTestData(100, 2) forKey:@"names-new" format:1 sharedName:@"new"];
    [self.store setData:VibeTestData(4000, 3) forKey:@"big" format:1 sharedName:nil];
    [self waitForQueue];

    // The oldest is the shared item, and the entry that names it then reads
    // as naming one that is not cached.
    XCTAssertFalse([self.store hasSharedItemForName:@"old" part:@"thumb"]);
    XCTAssertEqualObjects([self.store hitForKey:@"names-old" format:1].sharedName, @"old");
    XCTAssertTrue([self.store hasSharedItemForName:@"new" part:@"thumb"]);
    XCTAssertLessThanOrEqual(self.store.usage.bytes, 9000u);
}

- (void)testTheAgeCountsFromTheLastUse {
    [self.store setData:VibeTestData(10, 1) forKey:@"read" format:1 sharedName:nil];
    [self.store setData:VibeTestData(10, 2) forKey:@"unread" format:1 sharedName:nil];
    [self.store setData:VibeTestData(100 * 1024, 3) forKey:@"unread-file" format:1 sharedName:nil];

    [self.store setDayOffsetForTesting:100];
    XCTAssertNotNil([self.store hitForKey:@"read" format:1]);
    [self.store recordUsesNowForTesting];
    [self maintain];
    XCTAssertTrue([self.store hasEntryForKey:@"unread"]);

    [self.store setDayOffsetForTesting:200];
    [self maintain];
    XCTAssertTrue([self.store hasEntryForKey:@"read"]);
    XCTAssertFalse([self.store hasEntryForKey:@"unread"]);
    XCTAssertFalse([self.store hasEntryForKey:@"unread-file"]);
    XCTAssertEqual(self.store.fileNamesForTesting.count, 0u);
    XCTAssertEqual(self.store.usage.entries, 1u);
}

- (void)testAnAgeLimitOfZeroKeepsEverything {
    self.store.ageLimit = 0;
    [self.store setData:VibeTestData(10, 1) forKey:@"k" format:1 sharedName:nil];
    [self.store setDayOffsetForTesting:10000];
    [self maintain];
    XCTAssertTrue([self.store hasEntryForKey:@"k"]);
}

- (void)testTheDefaultsAreTodaysTerms {
    XCTAssertEqual(self.store.byteLimit, 1024ULL * 1024 * 1024);
    XCTAssertEqual(self.store.ageLimit, 180.0 * 86400);
}

// MARK: Opening

- (void)testAReopeningKeepsEverything {
    NSData *large = VibeTestData(100 * 1024, 1);
    [self.store setData:VibeTestData(10, 1) forKey:@"small" format:2 sharedName:@"p"];
    [self.store setData:large forKey:@"large" format:2 sharedName:nil];
    [self.store setSharedData:VibeTestData(20, 1) forName:@"p" part:@"thumb" format:2];
    VibeCacheUsage before = self.store.usage;
    [self reopen];
    VibeCacheUsage after = self.store.usage;
    XCTAssertEqual(after.entries, before.entries);
    XCTAssertEqual(after.sharedItems, before.sharedItems);
    XCTAssertEqual(after.bytes, before.bytes);
    XCTAssertEqualObjects([self.store hitForKey:@"large" format:2].data, large);
    XCTAssertNotNil([self.store sharedHitForName:@"p" part:@"thumb" format:2]);
}

- (void)testOneOpenAtATime {
    XCTAssertNil([self openStore]);
    [self.store close];
    VibeCacheStore *second = [self openStore];
    XCTAssertNotNil(second);
    [second close];
}

- (void)testAClosedStoreIsEmptyAndIgnoresWrites {
    [self.store setData:VibeTestData(10, 1) forKey:@"k" format:1 sharedName:nil];
    [self.store close];
    XCTAssertNil([self.store hitForKey:@"k" format:1]);
    [self.store setData:VibeTestData(10, 1) forKey:@"other" format:1 sharedName:nil];
    XCTAssertEqual(self.store.usage.entries, 0u);
}

- (void)testADatabaseThatWillNotOpenIsMadeAgain {
    [self.store setData:VibeTestData(100 * 1024, 1) forKey:@"large" format:1 sharedName:nil];
    [self.store close];
    NSString *database = [self.directory stringByAppendingPathComponent:@"Cache.sqlite"];
    for (NSString *suffix in @[@"-wal", @"-shm"]) {
        [NSFileManager.defaultManager removeItemAtPath:[database stringByAppendingString:suffix] error:NULL];
    }
    XCTAssertTrue([VibeTestData(8192, 7) writeToFile:database atomically:NO]);

    self.store = [self openStore];
    XCTAssertNotNil(self.store);
    XCTAssertEqual(self.store.usage.entries, 0u);
    XCTAssertEqual(self.store.fileNamesForTesting.count, 0u);
    [self.store setData:VibeTestData(10, 1) forKey:@"k" format:1 sharedName:nil];
    XCTAssertNotNil([self.store hitForKey:@"k" format:1]);
}

- (void)testACrashBetweenAFileAndItsRowLeavesNoEntryAndNoFile {
    [self.store setStopsBeforeFileRowForTesting:YES];
    [self.store setData:VibeTestData(100 * 1024, 1) forKey:@"k" format:1 sharedName:nil];
    XCTAssertFalse([self.store hasEntryForKey:@"k"]);
    XCTAssertEqual(self.store.fileNamesForTesting.count, 1u);
    XCTAssertEqual(self.store.usage.bytes, 0u);

    [self reopen];
    XCTAssertFalse([self.store hasEntryForKey:@"k"]);
    XCTAssertEqual(self.store.fileNamesForTesting.count, 0u);
}

- (void)testAFileOfTheWrongSizeIsAMissAndGoes {
    [self.store setData:VibeTestData(100 * 1024, 1) forKey:@"k" format:1 sharedName:nil];
    NSString *file = [self.filesPath stringByAppendingPathComponent:self.store.fileNamesForTesting.firstObject];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:file];
    [handle truncateAtOffset:10 error:NULL];
    [handle closeFile];

    XCTAssertNil([self.store hitForKey:@"k" format:1]);
    [self waitForQueue];
    XCTAssertFalse([self.store hasEntryForKey:@"k"]);
    XCTAssertEqual(self.store.fileNamesForTesting.count, 0u);
}

- (void)testAReadNeverWaitsForTheWriter {
    [self.store setData:VibeTestData(10, 1) forKey:@"k" format:1 sharedName:nil];
    dispatch_semaphore_t hold = dispatch_semaphore_create(0);
    [self.store performAfterQueuedWork:^{
        dispatch_semaphore_wait(hold, dispatch_time(DISPATCH_TIME_NOW, VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC));
    }];
    XCTAssertNotNil([self.store hitForKey:@"k" format:1]);
    XCTAssertEqual(self.store.usage.entries, 1u);
    dispatch_semaphore_signal(hold);
}

// MARK: Formats

- (void)testAnOlderRowIsAMissForACurrentRead {
    [self.store setData:VibeTestData(10, 1) forKey:@"k" format:3 sharedName:nil];
    XCTAssertNil([self.store hitForKey:@"k" format:4]);
    XCTAssertTrue([self.store hasEntryForKey:@"k"]);
}

- (void)testAnOlderRowAnswersAReadThatAcceptsIt {
    NSData *data = VibeTestData(10, 1);
    [self.store setData:data forKey:@"k" format:3 sharedName:@"p"];
    VibeCacheHit *hit = [self.store hitForKey:@"k" acceptingFormatsUpTo:4];
    XCTAssertEqualObjects(hit.data, data);
    XCTAssertEqual(hit.format, 3);
    XCTAssertTrue(hit.older);
    XCTAssertEqualObjects(hit.sharedName, @"p");

    hit = [self.store hitForKey:@"k" acceptingFormatsUpTo:3];
    XCTAssertFalse(hit.older);
}

- (void)testANewerRowIsAMissForEveryRead {
    [self.store setData:VibeTestData(10, 1) forKey:@"k" format:5 sharedName:nil];
    [self.store setSharedData:VibeTestData(10, 1) forName:@"p" part:@"thumb" format:5];
    XCTAssertNil([self.store hitForKey:@"k" format:4]);
    XCTAssertNil([self.store hitForKey:@"k" acceptingFormatsUpTo:4]);
    XCTAssertNil([self.store sharedHitForName:@"p" part:@"thumb" acceptingFormatsUpTo:4]);
}

- (void)testARewriteInTheCurrentFormatReplacesAnOlderRow {
    [self.store setData:VibeTestData(10, 1) forKey:@"k" format:3 sharedName:nil];
    NSData *current = VibeTestData(12, 2);
    [self.store setData:current forKey:@"k" format:4 sharedName:nil];
    VibeCacheHit *hit = [self.store hitForKey:@"k" format:4];
    XCTAssertEqualObjects(hit.data, current);
    XCTAssertEqual(self.store.usage.entries, 1u);
}

- (void)testAnOlderSharedItemIsMarked {
    [self.store setSharedData:VibeTestData(10, 1) forName:@"p" part:@"thumb" format:1];
    XCTAssertNil([self.store sharedHitForName:@"p" part:@"thumb" format:2]);
    VibeCacheHit *hit = [self.store sharedHitForName:@"p" part:@"thumb" acceptingFormatsUpTo:2];
    XCTAssertTrue(hit.older);
    XCTAssertNil(hit.sharedName);
}

// MARK: Shared items

- (void)testTwoEntriesShareOneItem {
    NSData *thumb = VibeTestData(9000, 1);
    NSData *rendition = VibeTestData(114 * 1024, 2);
    [self.store setSharedData:thumb forName:@"sha" part:@"thumb" format:1];
    [self.store setSharedData:rendition forName:@"sha" part:@"display" format:1];
    [self.store setData:VibeTestData(900, 1) forKey:@"a" format:1 sharedName:@"sha"];
    [self.store setData:VibeTestData(900, 2) forKey:@"b" format:1 sharedName:@"sha"];

    VibeCacheUsage usage = self.store.usage;
    XCTAssertEqual(usage.entries, 2u);
    XCTAssertEqual(usage.sharedItems, 2u);
    XCTAssertEqual(self.store.fileNamesForTesting.count, 1u);
    XCTAssertEqualObjects([self.store sharedHitForName:@"sha" part:@"thumb" format:1].data, thumb);
    XCTAssertEqualObjects([self.store sharedHitForName:@"sha" part:@"display" format:1].data, rendition);

    [self.store removeEntryForKey:@"a"];
    XCTAssertTrue([self.store hasSharedItemForName:@"sha" part:@"display"]);
    [self.store removeEntryForKey:@"b"];
    XCTAssertFalse([self.store hasSharedItemForName:@"sha" part:@"thumb"]);
    XCTAssertFalse([self.store hasSharedItemForName:@"sha" part:@"display"]);
    XCTAssertEqual(self.store.fileNamesForTesting.count, 0u);
    XCTAssertEqual(self.store.usage.bytes, 0u);
}

- (void)testARewriteNamingAnotherItemLetsTheOldOneGo {
    [self.store setSharedData:VibeTestData(10, 1) forName:@"old" part:@"thumb" format:1];
    [self.store setData:VibeTestData(10, 1) forKey:@"k" format:1 sharedName:@"old"];
    [self.store setData:VibeTestData(10, 1) forKey:@"k" format:1 sharedName:@"new"];
    XCTAssertFalse([self.store hasSharedItemForName:@"old" part:@"thumb"]);
}

- (void)testAMoveKeepsTheItem {
    [self.store setSharedData:VibeTestData(10, 1) forName:@"p" part:@"thumb" format:1];
    [self.store setData:VibeTestData(10, 1) forKey:@"old" format:1 sharedName:@"p"];
    XCTAssertTrue([self.store moveEntryFromKey:@"old" toKey:@"new"]);
    XCTAssertTrue([self.store hasSharedItemForName:@"p" part:@"thumb"]);
}

- (void)testTheDailySweepTakesItemsNoEntryNames {
    [self.store setSharedData:VibeTestData(10, 1) forName:@"named" part:@"thumb" format:1];
    [self.store setData:VibeTestData(10, 1) forKey:@"k" format:1 sharedName:@"named"];
    [self.store setSharedData:VibeTestData(10, 1) forName:@"orphan" part:@"thumb" format:1];
    [self.store setSharedData:VibeTestData(100 * 1024, 1) forName:@"orphan" part:@"display" format:1];
    [self maintain];
    XCTAssertTrue([self.store hasSharedItemForName:@"named" part:@"thumb"]);
    XCTAssertFalse([self.store hasSharedItemForName:@"orphan" part:@"thumb"]);
    XCTAssertFalse([self.store hasSharedItemForName:@"orphan" part:@"display"]);
    XCTAssertEqual(self.store.fileNamesForTesting.count, 0u);
}

@end
