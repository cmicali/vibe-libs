//
//  AudioTrackMetadataCacheTests.mm
//
//  The cache over a store of its own, with the real loader, parse and
//  coordinator. Objective-C++, since the tag fixtures are C++.
//

#import <XCTest/XCTest.h>
#import <objc/runtime.h>

#import "AudioTrackArtwork.h"
#import "AudioTrackMetadataCache.h"
#import "AudioTrackMetadataInternal.h"
#import "AudioTrackMetadataTagFixtures.h"
#import "ImageFixtures.h"
#import "PlatformImage.h"
#import "MetadataLoaderTestFakes.h"
#import "PINCache+VibeAudioCache.h"
#import "VibeTestNegativeWindow.h"

@interface AudioTrackMetadataCacheTests : XCTestCase
@end

@implementation AudioTrackMetadataCacheTests {
    NSURL *_dir;
}

- (void)setUp {
    [super setUp];
    _dir = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
                                   [@"vibe-metadata-cache-tests-" stringByAppendingString:NSUUID.UUID.UUIDString]]
                      isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:_dir withIntermediateDirectories:YES attributes:nil
                                                 error:NULL];
}

- (void)tearDown {
    [NSFileManager.defaultManager removeItemAtURL:_dir error:NULL];
    [super tearDown];
}

- (BOOL)waitFor:(BOOL (^)(void))condition within:(NSTimeInterval)seconds {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!condition() && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return condition();
}

// The store's build is held at a gate, so the load is issued before the
// store exists. The load waits for the store rather than parsing uncached.
// Once the gate opens it is delivered and filed, so a second cache over the
// same root hits from the disk alone.
- (void)testALoadIssuedBeforeTheStoreExistsIsFiled {
    NSURL *url = VibeWriteTagFixture(_dir, VibeTagFixtureWAVID3, nil, NULL);
    XCTAssertNotNil(url);
    NSString *root = [_dir URLByAppendingPathComponent:@"cache"].path;
    dispatch_semaphore_t building = dispatch_semaphore_create(0);
    dispatch_semaphore_t gate = dispatch_semaphore_create(0);
    dispatch_semaphore_t returned = dispatch_semaphore_create(0);
    SEL selector = @selector(audioCacheWithName:rootPath:);
    Method method = class_getClassMethod(PINCache.class, selector);
    IMP original = method_getImplementation(method);
    IMP held = imp_implementationWithBlock(^PINCache *(Class cls, NSString *name, NSString *rootPath) {
        // Only the tag store's build is held. The art's stores build first.
        if (![name isEqualToString:AudioTrackMetadataCache.cacheName]) {
            return ((PINCache *(*)(Class, SEL, NSString *, NSString *))original)(cls, selector, name, rootPath);
        }
        dispatch_semaphore_signal(building);
        dispatch_semaphore_wait(gate, dispatch_time(DISPATCH_TIME_NOW,
                                                    (int64_t)(VIBE_TEST_GATE_TIMEOUT * NSEC_PER_SEC)));
        PINCache *store = ((PINCache *(*)(Class, SEL, NSString *, NSString *))original)(cls, selector, name,
                                                                                         rootPath);
        dispatch_semaphore_signal(returned);
        return store;
    });
    VibeMetadataLoaderDelegate *delegate = [[VibeMetadataLoaderDelegate alloc] init];
    VibeLoaderTestTrack *track = [VibeLoaderTestTrack withURL:url];
    AudioTrackMetadataCache *cache = nil;
    method_setImplementation(method, held);
    @try {
        cache = [[AudioTrackMetadataCache alloc] initWithRootPath:root];
        cache.delegate = delegate;
        XCTAssertEqual(dispatch_semaphore_wait(building, dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC))), 0, @"the store's build never started");
        [cache loadMetadataNow:track];
        XCTAssertFalse([self waitFor:^BOOL { return delegate.deliveredTracks.count > 0; }
                              within:kVibeTestNegativeWindow],
                       @"the load parsed without its store");
    }
    @finally {
        dispatch_semaphore_signal(gate);
        method_setImplementation(method, original);
        // TRAP: the held block is still running on the cache's queue when
        // the gate opens. imp_removeBlock frees it, so removing it before
        // the block returns crashes.
        if (dispatch_semaphore_wait(returned, dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC))) == 0) {
            imp_removeBlock(held);
        }
    }
    XCTAssertTrue([self waitFor:^BOOL { return delegate.deliveredTracks.count > 0; }
                         within:VIBE_TEST_HANG_TIMEOUT]);
    XCTAssertTrue(track.metadata.parsedOK);
    XCTAssertEqualObjects(track.metadata.title, kVibeTagTitle);

    AudioTrackMetadataCache *reopened = [[AudioTrackMetadataCache alloc] initWithRootPath:root];
    VibeMetadataLoaderDelegate *hits = [[VibeMetadataLoaderDelegate alloc] init];
    reopened.delegate = hits;
    VibeLoaderTestTrack *again = [VibeLoaderTestTrack withURL:url];
    [reopened loadCachedMetadata:@[again]];
    XCTAssertTrue([self waitFor:^BOOL { return hits.deliveredTracks.count > 0; } within:VIBE_TEST_HANG_TIMEOUT],
                  @"the load before the store was not filed");
    XCTAssertEqualObjects(again.metadata.title, kVibeTagTitle);
    cache.delegate = nil;
    reopened.delegate = nil;
}

// Each store's name carries its version as DiskCache's removal reads it, so
// a format bump removes the old store and keeps the current ones.
- (void)testTheStoreNamesFollowTheVersionRule {
    NSString *root = [_dir URLByAppendingPathComponent:@"stores"].path;
    NSMutableArray<NSString *> *current = [NSMutableArray array];
    for (NSString *name in AudioTrackMetadataCache.cacheNames) {
        [current addObject:[@"com.pinterest.PINDiskCache." stringByAppendingString:name]];
    }
    NSArray<NSString *> *old = @[@"com.pinterest.PINDiskCache.Audio Track Metadata v8",
                                 @"com.pinterest.PINDiskCache.Audio Track Thumbnails v0",
                                 @"com.pinterest.PINDiskCache.Audio Track Display Art"];
    for (NSString *store in [current arrayByAddingObjectsFromArray:old]) {
        XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtPath:[root stringByAppendingPathComponent:store]
                                              withIntermediateDirectories:YES attributes:nil error:nil]);
    }
    XCTestExpectation *removed = [self expectationWithDescription:@"removed"];
    [PINCache removeOtherAudioCacheVersionsKeeping:AudioTrackMetadataCache.cacheNames rootPath:root completion:^{
        [removed fulfill];
    }];
    [self waitForExpectations:@[removed] timeout:VIBE_TEST_HANG_TIMEOUT];
    NSArray<NSString *> *left = [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil];
    XCTAssertEqualObjects([left sortedArrayUsingSelector:@selector(compare:)],
                          [current sortedArrayUsingSelector:@selector(compare:)]);
}

#pragma mark - The art's stores

// A tagged file with a picture of the rendition's size, so the rendition is
// the picture's bytes.
- (NSURL *)fileWithArt {
    NSURL *url = VibeWriteTagFixture(_dir, VibeTagFixtureMP3ID3v24, VibeImageOfColor(600, 1, 0, 0, YES), NULL);
    XCTAssertNotNil(url);
    return url;
}

- (VibeMetadataReadResult *)read:(NSURL *)url
                         through:(AudioTrackMetadataCache *)cache
                          policy:(VibeMetadataReadPolicy)policy {
    __block VibeMetadataReadResult *answer = nil;
    XCTestExpectation *done = [self expectationWithDescription:@"read"];
    dispatch_queue_t queue = dispatch_queue_create("vibe-libs.tests.metadata-cache", DISPATCH_QUEUE_SERIAL);
    [cache readMetadataOfURLs:@[url] policy:policy deliveryQueue:queue
                       result:^(VibeMetadataReadResult *result) {
                           answer = result;
                       }
                   completion:^{
                       [done fulfill];
                   }];
    [self waitForExpectations:@[done] timeout:VIBE_TEST_HANG_TIMEOUT];
    return answer;
}

// One store, opened apart from the cache, as a reader of its files.
- (PINCache *)store:(NSString *)name under:(NSString *)root {
    return [PINCache audioCacheWithName:name rootPath:root];
}

- (nullable NSImage *)thumbnailOf:(AudioTrackMetadata *)metadata {
    __block NSImage *thumbnail = [metadata cachedThumbnail];
    [self waitFor:^BOOL {
        thumbnail = [metadata cachedThumbnail];
        return thumbnail != nil;
    } within:VIBE_TEST_HANG_TIMEOUT];
    return thumbnail;
}

// The tags, the thumbnail, and the rendition each go in their own store, so
// each has its own budget, and art never pushes tags out.
- (void)testArtIsFiledInStoresOfItsOwn {
    NSURL *url = [self fileWithArt];
    NSString *root = [_dir URLByAppendingPathComponent:@"cache"].path;
    AudioTrackMetadataCache *cache = [[AudioTrackMetadataCache alloc] initWithRootPath:root];
    VibeMetadataReadResult *answer = [self read:url through:cache policy:VibeMetadataReadPolicyLocal];
    XCTAssertEqual(answer.outcome, VibeMetadataReadOutcomeRead);
    XCTAssertFalse(answer.fromCache);
    NSString *key = answer.cacheKey;
    XCTAssertNotNil(key);

    AudioTrackMetadata *filed =
            (AudioTrackMetadata *)[[self store:AudioTrackMetadataCache.cacheName under:root].diskCache objectForKey:key];
    XCTAssertEqualObjects(filed.title, kVibeTagTitle);
    XCTAssertTrue(filed.artwork.hasEmbeddedArt, @"the entry says the file has art");
    XCTAssertNil(filed.artwork.encodedThumbnailDataForStorage, @"the entry holds no art");
    NSData *thumbnail =
            (NSData *)[[self store:AudioTrackMetadataCache.thumbnailCacheName under:root].diskCache objectForKey:key];
    CGSize size = VibeEncodedImagePixelSize(thumbnail);
    XCTAssertEqual(MAX(size.width, size.height), kVibeThumbnailArtDimension);
    NSData *rendition =
            (NSData *)[[self store:AudioTrackMetadataCache.displayArtCacheName under:root].diskCache objectForKey:key];
    XCTAssertEqualObjects(rendition, VibeImageOfColor(600, 1, 0, 0, YES));
}

// A hit holds no art bytes. Its row thumbnail decodes from the thumbnail
// store, with the rendition gone, and never reads the file.
- (void)testAHitDecodesItsThumbnailFromTheThumbnailStore {
    NSURL *url = [self fileWithArt];
    NSString *root = [_dir URLByAppendingPathComponent:@"cache"].path;
    NSString *key = [self read:url through:[[AudioTrackMetadataCache alloc] initWithRootPath:root]
                        policy:VibeMetadataReadPolicyLocal].cacheKey;
    [[self store:AudioTrackMetadataCache.displayArtCacheName under:root].diskCache removeObjectForKey:key];

    AudioTrackMetadataCache *reopened = [[AudioTrackMetadataCache alloc] initWithRootPath:root];
    VibeMetadataReadResult *hit = [self read:url through:reopened policy:VibeMetadataReadPolicyCacheOnly];
    XCTAssertEqual(hit.outcome, VibeMetadataReadOutcomeRead);
    XCTAssertTrue(hit.fromCache);
    XCTAssertNil(hit.metadata.artwork.encodedThumbnailDataForStorage);
    NSImage *thumbnail = [self thumbnailOf:hit.metadata];
    XCTAssertNotNil(thumbnail, @"the thumbnail store's bytes");
    XCTAssertNotNil(hit.metadata.artwork.archivedThumbnailProvider, @"a read that found bytes keeps its provider");
}

// A hit whose thumbnail was evicted decodes it from the rendition, and drops
// the provider that read nothing.
- (void)testAHitWhoseThumbnailIsGoneDecodesFromTheRendition {
    NSURL *url = [self fileWithArt];
    NSString *root = [_dir URLByAppendingPathComponent:@"cache"].path;
    NSString *key = [self read:url through:[[AudioTrackMetadataCache alloc] initWithRootPath:root]
                        policy:VibeMetadataReadPolicyLocal].cacheKey;
    [[self store:AudioTrackMetadataCache.thumbnailCacheName under:root].diskCache removeObjectForKey:key];

    AudioTrackMetadataCache *reopened = [[AudioTrackMetadataCache alloc] initWithRootPath:root];
    VibeMetadataReadResult *hit = [self read:url through:reopened policy:VibeMetadataReadPolicyCacheOnly];
    XCTAssertTrue(hit.fromCache);
    XCTAssertNotNil([self thumbnailOf:hit.metadata], @"the rendition stands in");
    XCTAssertNil(hit.metadata.artwork.archivedThumbnailProvider);
}

// The disk usage counts all three stores, and an invalidation empties them.
- (void)testUsageCountsAndInvalidationEmptiesEveryStore {
    NSURL *url = [self fileWithArt];
    NSString *root = [_dir URLByAppendingPathComponent:@"cache"].path;
    AudioTrackMetadataCache *cache = [[AudioTrackMetadataCache alloc] initWithRootPath:root];
    [self read:url through:cache policy:VibeMetadataReadPolicyLocal];
    __block NSUInteger files = NSNotFound;
    __block unsigned long long bytes = 0;
    void (^usage)(void) = ^{
        XCTestExpectation *counted = [self expectationWithDescription:@"counted"];
        [cache diskUsageWithCompletion:^(NSUInteger fileCount, unsigned long long totalBytes) {
            files = fileCount;
            bytes = totalBytes;
            [counted fulfill];
        }];
        [self waitForExpectations:@[counted] timeout:VIBE_TEST_HANG_TIMEOUT];
    };
    usage();
    XCTAssertEqual(files, 3u, @"the tags, the thumbnail, and the rendition");
    XCTAssertGreaterThan(bytes, 0u);

    XCTestExpectation *emptied = [self expectationWithDescription:@"emptied"];
    [cache invalidateWithCompletion:^{
        [emptied fulfill];
    }];
    [self waitForExpectations:@[emptied] timeout:VIBE_TEST_HANG_TIMEOUT];
    usage();
    XCTAssertEqual(files, 0u);
}

@end
