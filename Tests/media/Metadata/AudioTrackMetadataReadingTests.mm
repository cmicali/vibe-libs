//
//  AudioTrackMetadataReadingTests.mm
//
//  readMetadataOfURLs: over a cache of its own, with the real store and
//  parse. The parse seam counts parses, holds one, or stands in for one.
//  Objective-C++, since the tag fixtures are C++.
//

#import <XCTest/XCTest.h>

#import "AudioLoadingConfiguration.h"
#import "AudioTrackMetadataCache.h"
#import "AudioTrackMetadataCache+Debug.h"
#import "AudioTrackMetadataInternal.h"
#import "AudioTrackMetadataTagFixtures.h"
#import "MetadataLoaderTestFakes.h"
#import "NSURL+FilenameTitle.h"
#import "NSURL+Hash.h"
#import "PlaceholderFiles+Debug.h"

#include <stdatomic.h>
#include <sys/resource.h>

static const void *const kVibeReadingTestQueueKey = &kVibeReadingTestQueueKey;

@interface AudioTrackMetadataReadingTests : XCTestCase
@end

@implementation AudioTrackMetadataReadingTests {
    NSURL *_dir;
    AudioTrackMetadataCache *_cache;
    dispatch_queue_t _delivery;
    atomic_int _parses;
}

- (void)setUp {
    [super setUp];
    _dir = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
                                   [@"vibe-metadata-reading-tests-" stringByAppendingString:NSUUID.UUID.UUIDString]]
                      isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:_dir withIntermediateDirectories:YES attributes:nil
                                                 error:NULL];
    _cache = [[AudioTrackMetadataCache alloc] initWithRootPath:[_dir URLByAppendingPathComponent:@"cache"].path];
    _delivery = dispatch_queue_create("vibe-libs.tests.metadata-reading", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(_delivery, kVibeReadingTestQueueKey, (void *)kVibeReadingTestQueueKey, NULL);
    atomic_store(&_parses, 0);
}

- (void)tearDown {
    [PlaceholderFiles setDatalessProbe:nil];
    _cache = nil;
    [NSFileManager.defaultManager removeItemAtURL:_dir error:NULL];
    [super tearDown];
}

// The real parse, counted.
- (void)countParses {
    __weak __typeof(self) weakSelf = self;
    [_cache debugSetReadingFileParser:^AudioTrackMetadata *(NSURL *url) {
        __typeof(self) strongSelf = weakSelf;
        if (strongSelf) {
            atomic_fetch_add(&strongSelf->_parses, 1);
        }
        return [AudioTrackMetadata metadataWithURL:url displayArtData:NULL];
    }];
}

- (NSURL *)taggedFile {
    NSURL *url = VibeWriteTagFixture(_dir, VibeTagFixtureWAVID3, nil, NULL);
    XCTAssertNotNil(url);
    return url;
}

- (NSURL *)fileNamed:(NSString *)name holding:(NSData *)bytes {
    NSURL *url = [_dir URLByAppendingPathComponent:name];
    XCTAssertTrue([bytes writeToURL:url atomically:YES]);
    return url;
}

// FLAC inside Ogg, which playback refuses, and so the parse does too
// (AudioTrackMetadataTagTests).
- (NSURL *)fileThatFailsToParse:(NSString *)name {
    NSMutableData *bytes = [NSMutableData dataWithBytes:"OggS" length:4];
    [bytes increaseLengthBy:24];
    [bytes appendBytes:"\x7F" "FLAC\x01\x00\x00\x01" "fLaC\x80\x00\x00\x22" length:17];
    [bytes increaseLengthBy:34];
    return [self fileNamed:name holding:bytes];
}

// Reads and waits for completion. Every URL is answered once, on the
// delivery queue, before completion.
- (NSArray<VibeMetadataReadResult *> *)read:(NSArray<NSURL *> *)urls policy:(VibeMetadataReadPolicy)policy {
    return [self read:urls policy:policy started:nil];
}

- (NSArray<VibeMetadataReadResult *> *)read:(NSArray<NSURL *> *)urls
                                     policy:(VibeMetadataReadPolicy)policy
                                    started:(void (^)(NSProgress *progress))started {
    NSMutableArray<VibeMetadataReadResult *> *results = [NSMutableArray array];
    __block BOOL offQueue = NO;
    __block BOOL answeredAfterCompletion = NO;
    __block BOOL completed = NO;
    XCTestExpectation *done = [self expectationWithDescription:@"completion"];
    NSProgress *progress = [_cache readMetadataOfURLs:urls policy:policy deliveryQueue:_delivery
                                               result:^(VibeMetadataReadResult *result) {
        offQueue |= dispatch_get_specific(kVibeReadingTestQueueKey) == NULL;
        answeredAfterCompletion |= completed;
        [results addObject:result];
    } completion:^{
        offQueue |= dispatch_get_specific(kVibeReadingTestQueueKey) == NULL;
        completed = YES;
        [done fulfill];
    }];
    if (started) {
        started(progress);
    }
    [self waitForExpectations:@[done] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertFalse(offQueue, @"an answer or the completion ran off the delivery queue");
    XCTAssertFalse(answeredAfterCompletion);
    XCTAssertEqual(results.count, urls.count);
    NSCountedSet<NSURL *> *asked = [NSCountedSet setWithArray:urls];
    NSCountedSet<NSURL *> *answered = [NSCountedSet setWithArray:[results valueForKey:@"url"]];
    XCTAssertEqualObjects(answered, asked, @"each URL is answered once");
    XCTAssertEqual(progress.completedUnitCount, (int64_t)urls.count);
    return results;
}

- (void)testATaggedFileIsParsedOnceThenReadFromTheCache {
    [self countParses];
    NSURL *url = [self taggedFile];
    VibeMetadataReadResult *first = [self read:@[url] policy:VibeMetadataReadPolicyLocal].firstObject;
    XCTAssertEqual(first.outcome, VibeMetadataReadOutcomeRead);
    XCTAssertFalse(first.fromCache);
    XCTAssertEqualObjects(first.cacheKey, url.cacheKey);
    XCTAssertEqualObjects(first.metadata.cacheKey, url.cacheKey);
    XCTAssertTrue(first.metadata.parsedOK);
    XCTAssertEqualObjects(first.metadata.title, kVibeTagTitle);
    XCTAssertEqualObjects(first.metadata.album, kVibeTagAlbum);

    VibeMetadataReadResult *second = [self read:@[url] policy:VibeMetadataReadPolicyLocal].firstObject;
    XCTAssertEqual(second.outcome, VibeMetadataReadOutcomeRead);
    XCTAssertTrue(second.fromCache);
    XCTAssertEqualObjects(second.metadata.title, kVibeTagTitle);
    XCTAssertEqual(atomic_load(&_parses), 1);
}

// A read files its parse where the sweep's cache-only lookup finds it.
- (void)testAReadIsFiledForTheSweep {
    NSURL *url = [self taggedFile];
    XCTAssertEqual([self read:@[url] policy:VibeMetadataReadPolicyLocal].firstObject.outcome,
                   VibeMetadataReadOutcomeRead);
    AudioTrackMetadataCache *reopened =
            [[AudioTrackMetadataCache alloc] initWithRootPath:[_dir URLByAppendingPathComponent:@"cache"].path];
    VibeMetadataLoaderDelegate *hits = [[VibeMetadataLoaderDelegate alloc] init];
    reopened.delegate = hits;
    VibeLoaderTestTrack *track = [VibeLoaderTestTrack withURL:url];
    [reopened loadCachedMetadata:@[track]];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:VIBE_TEST_HANG_TIMEOUT];
    while (hits.deliveredTracks.count == 0 && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    XCTAssertEqual(hits.deliveredTracks.count, 1u, @"the read was not filed");
    XCTAssertEqualObjects(track.metadata.title, kVibeTagTitle);
    reopened.delegate = nil;
}

// A file with no title tag keeps its file name as the title, as the sweep's
// parse does.
- (void)testAnUntaggedFileTakesItsFileNameAsItsTitle {
    NSURL *untagged = nil;
    XCTAssertNotNil(VibeWriteTagFixture(_dir, VibeTagFixtureWAVID3, nil, &untagged));
    if (!untagged) {
        return;
    }
    VibeMetadataReadResult *result = [self read:@[untagged] policy:VibeMetadataReadPolicyLocal].firstObject;
    XCTAssertEqual(result.outcome, VibeMetadataReadOutcomeRead);
    XCTAssertEqualObjects(result.metadata.title, untagged.filenameTitle);
}

- (void)testAMissingFileIsMissing {
    [self countParses];
    NSURL *url = [_dir URLByAppendingPathComponent:@"gone.mp3"];
    VibeMetadataReadResult *result = [self read:@[url] policy:VibeMetadataReadPolicyLocal].firstObject;
    XCTAssertEqual(result.outcome, VibeMetadataReadOutcomeMissing);
    XCTAssertNil(result.cacheKey);
    XCTAssertNil(result.metadata);
    XCTAssertEqual(atomic_load(&_parses), 0);
}

- (void)testAFileNeitherParserReadsIsNotParsedAndNotCached {
    [self countParses];
    NSURL *url = [self fileThatFailsToParse:@"not audio.flac"];
    VibeMetadataReadResult *result = [self read:@[url] policy:VibeMetadataReadPolicyLocal].firstObject;
    XCTAssertEqual(result.outcome, VibeMetadataReadOutcomeNotParsed);
    XCTAssertFalse(result.metadata.parsedOK);
    XCTAssertEqualObjects(result.metadata.title, url.filenameTitle);
    XCTAssertEqualObjects(result.cacheKey, url.cacheKey);
    XCTAssertEqual([self read:@[url] policy:VibeMetadataReadPolicyLocal].firstObject.outcome,
                   VibeMetadataReadOutcomeNotParsed);
    XCTAssertEqual(atomic_load(&_parses), 2, @"a failed parse was cached");
}

- (void)testAFileThatCannotBeOpenedIsUnreadable {
    [self countParses];
    NSURL *url = [self taggedFile];
    XCTAssertTrue([NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions: @0}
                                                 ofItemAtPath:url.path error:NULL]);
    VibeMetadataReadResult *result = [self read:@[url] policy:VibeMetadataReadPolicyLocal].firstObject;
    [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions: @0644} ofItemAtPath:url.path error:NULL];
    XCTAssertEqual(result.outcome, VibeMetadataReadOutcomeUnreadable);
    XCTAssertEqualObjects(result.error.domain, NSPOSIXErrorDomain);
    XCTAssertEqual(result.error.code, EACCES);
    XCTAssertEqual(atomic_load(&_parses), 0);
}

// A placeholder gets the cache alone: a miss parses nothing, and a hit
// answers from the cache.
- (void)testAPlaceholderGetsTheCacheAlone {
    [self countParses];
    NSURL *cachedURL = [self taggedFile];
    XCTAssertEqual([self read:@[cachedURL] policy:VibeMetadataReadPolicyLocal].firstObject.outcome,
                   VibeMetadataReadOutcomeRead);
    NSURL *uncached = nil;
    XCTAssertNotNil(VibeWriteTagFixture(_dir, VibeTagFixtureWAVInfo, nil, &uncached));
    if (!uncached) {
        return;
    }
    [PlaceholderFiles setDatalessProbe:^BOOL(NSURL *url) { return YES; }];
    NSArray<VibeMetadataReadResult *> *results = [self read:@[cachedURL, uncached] policy:VibeMetadataReadPolicyLocal];
    for (VibeMetadataReadResult *result in results) {
        if ([result.url isEqual:cachedURL]) {
            XCTAssertEqual(result.outcome, VibeMetadataReadOutcomeRead);
            XCTAssertTrue(result.fromCache);
            XCTAssertEqualObjects(result.metadata.title, kVibeTagTitle);
        } else {
            XCTAssertEqual(result.outcome, VibeMetadataReadOutcomeCacheMiss);
            XCTAssertNil(result.metadata);
            XCTAssertEqualObjects(result.cacheKey, uncached.cacheKey);
        }
    }
    XCTAssertEqual(atomic_load(&_parses), 1);
}

- (void)testCacheOnlyNeverParsesALocalFile {
    [self countParses];
    NSURL *url = [self taggedFile];
    VibeMetadataReadResult *result = [self read:@[url] policy:VibeMetadataReadPolicyCacheOnly].firstObject;
    XCTAssertEqual(result.outcome, VibeMetadataReadOutcomeCacheMiss);
    XCTAssertEqual(atomic_load(&_parses), 0);
}

// The parse runs with materialization off for its thread.
- (void)testTheParseRunsWithMaterializationOff {
    __block atomic_int policy = -1;
    [_cache debugSetReadingFileParser:^AudioTrackMetadata *(NSURL *url) {
        atomic_store(&policy, getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD));
        return [AudioTrackMetadata metadataWithURL:url displayArtData:NULL];
    }];
    XCTAssertEqual([self read:@[[self taggedFile]] policy:VibeMetadataReadPolicyLocal].firstObject.outcome,
                   VibeMetadataReadOutcomeRead);
    XCTAssertEqual(atomic_load(&policy), IOPOL_MATERIALIZE_DATALESS_FILES_OFF);
}

// A file the provider freed during the parse fails under the policy, and is
// a cache miss, not a file that is not audio.
- (void)testAFileEvictedDuringItsParseIsACacheMiss {
    NSURL *junk = [self fileThatFailsToParse:@"junk.flac"];
    NSURL *url = [self taggedFile];
    [_cache debugSetReadingFileParser:^AudioTrackMetadata *(NSURL *parsed) {
        [PlaceholderFiles setDatalessProbe:^BOOL(NSURL *probed) { return [probed isEqual:url]; }];
        return [AudioTrackMetadata metadataWithURL:junk displayArtData:NULL];
    }];
    VibeMetadataReadResult *result = [self read:@[url] policy:VibeMetadataReadPolicyLocal].firstObject;
    XCTAssertEqual(result.outcome, VibeMetadataReadOutcomeCacheMiss);
    XCTAssertNil(result.metadata);
}

// A file that changes during its parse is answered Changed, and nothing is
// filed, so the next read parses the new version.
- (void)testAFileChangedDuringItsParseIsNotFiled {
    NSURL *url = [self taggedFile];
    __block atomic_int parses = 0;
    [_cache debugSetReadingFileParser:^AudioTrackMetadata *(NSURL *parsed) {
        AudioTrackMetadata *metadata = [AudioTrackMetadata metadataWithURL:parsed displayArtData:NULL];
        if (atomic_fetch_add(&parses, 1) == 0) {
            NSDate *later = [NSDate dateWithTimeIntervalSinceNow:60];
            [NSFileManager.defaultManager setAttributes:@{NSFileModificationDate: later} ofItemAtPath:parsed.path
                                                  error:NULL];
        }
        return metadata;
    }];
    NSString *before = url.cacheKey;
    VibeMetadataReadResult *changed = [self read:@[url] policy:VibeMetadataReadPolicyLocal].firstObject;
    XCTAssertEqual(changed.outcome, VibeMetadataReadOutcomeChanged);
    XCTAssertEqualObjects(changed.cacheKey, before);
    XCTAssertNil(changed.metadata);
    VibeMetadataReadResult *again = [self read:@[url] policy:VibeMetadataReadPolicyLocal].firstObject;
    XCTAssertEqual(again.outcome, VibeMetadataReadOutcomeRead);
    XCTAssertFalse(again.fromCache);
    XCTAssertEqualObjects(again.cacheKey, url.cacheKey);
    XCTAssertEqual(atomic_load(&parses), 2);
}

// The parses run no wider than the configured local concurrency.
- (void)testTheParsesStayWithinTheConfiguredConcurrency {
    NSURL *source = [self taggedFile];
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (NSUInteger i = 0; i < 24; i++) {
        NSURL *copy = [_dir URLByAppendingPathComponent:[NSString stringWithFormat:@"copy %lu.wav", (unsigned long)i]];
        XCTAssertTrue([NSFileManager.defaultManager copyItemAtURL:source toURL:copy error:NULL]);
        [urls addObject:copy];
    }
    __block atomic_int running = 0;
    __block atomic_int widest = 0;
    [_cache debugSetReadingFileParser:^AudioTrackMetadata *(NSURL *url) {
        int now = atomic_fetch_add(&running, 1) + 1;
        int seen = atomic_load(&widest);
        while (now > seen && !atomic_compare_exchange_weak(&widest, &seen, now)) {
        }
        [NSThread sleepForTimeInterval:0.02];
        atomic_fetch_sub(&running, 1);
        return [AudioTrackMetadata metadataWithURL:url displayArtData:NULL];
    }];
    NSArray<VibeMetadataReadResult *> *results = [self read:urls policy:VibeMetadataReadPolicyLocal];
    for (VibeMetadataReadResult *result in results) {
        XCTAssertEqual(result.outcome, VibeMetadataReadOutcomeRead);
    }
    NSInteger bound = (NSInteger)_cache.loadingConfiguration.localMetadataParseConcurrency;
    XCTAssertLessThanOrEqual(atomic_load(&widest), bound);
    XCTAssertGreaterThan(atomic_load(&widest), 1, @"the parses never overlapped");
}

// Cancelling answers every file not begun as Cancelled. The parse already
// begun finishes, and completion still runs last.
- (void)testCancellingAnswersTheFilesNotBegun {
    NSURL *source = [self taggedFile];
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (NSUInteger i = 0; i < 12; i++) {
        NSURL *copy = [_dir URLByAppendingPathComponent:[NSString stringWithFormat:@"held %lu.wav", (unsigned long)i]];
        XCTAssertTrue([NSFileManager.defaultManager copyItemAtURL:source toURL:copy error:NULL]);
        [urls addObject:copy];
    }
    dispatch_semaphore_t entered = dispatch_semaphore_create(0);
    dispatch_semaphore_t gate = dispatch_semaphore_create(0);
    [_cache debugSetReadingFileParser:^AudioTrackMetadata *(NSURL *url) {
        dispatch_semaphore_signal(entered);
        dispatch_semaphore_wait(gate, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(VIBE_TEST_GATE_TIMEOUT * NSEC_PER_SEC)));
        return [AudioTrackMetadata metadataWithURL:url displayArtData:NULL];
    }];
    NSUInteger workers = _cache.loadingConfiguration.localMetadataParseConcurrency;
    NSArray<VibeMetadataReadResult *> *results = [self read:urls policy:VibeMetadataReadPolicyLocal
                                                    started:^(NSProgress *progress) {
        for (NSUInteger i = 0; i < workers; i++) {
            XCTAssertEqual(dispatch_semaphore_wait(entered, dispatch_time(DISPATCH_TIME_NOW,
                    (int64_t)(VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC))), 0);
        }
        [progress cancel];
        for (NSUInteger i = 0; i < workers; i++) {
            dispatch_semaphore_signal(gate);
        }
    }];
    NSUInteger read = 0;
    NSUInteger cancelled = 0;
    for (VibeMetadataReadResult *result in results) {
        read += result.outcome == VibeMetadataReadOutcomeRead;
        cancelled += result.outcome == VibeMetadataReadOutcomeCancelled;
        if (result.outcome == VibeMetadataReadOutcomeCancelled) {
            XCTAssertNil(result.cacheKey);
            XCTAssertNil(result.metadata);
        }
    }
    XCTAssertEqual(read, workers);
    XCTAssertEqual(cancelled, urls.count - workers);
}

- (void)testNoFilesCompleteAtOnce {
    XCTAssertEqual([self read:@[] policy:VibeMetadataReadPolicyLocal].count, 0u);
}

@end
