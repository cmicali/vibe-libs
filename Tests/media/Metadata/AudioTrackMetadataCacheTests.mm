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
#import "NSURL+Hash.h"
#import "VibeTestFileDates.h"
#import "AudioTrackMetadataCache+Debug.h"
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
                                 @"com.pinterest.PINDiskCache.Audio Track Metadata v10",
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

    // An entry of the store before the extra tags is never read: the file
    // parses again, and its new tags are read.
    NSURL *url = VibeWriteTagFixture(_dir, VibeTagFixtureFLAC, nil, NULL);
    PINCache *v10 = [self store:@"Audio Track Metadata v10" under:root];
    [v10.diskCache setObject:[AudioTrackMetadata metadataWithURL:url displayArtData:NULL] forKey:url.cacheKey];
    AudioTrackMetadataCache *cache = [[AudioTrackMetadataCache alloc] initWithRootPath:root];
    XCTAssertEqual([self read:url through:cache policy:VibeMetadataReadPolicyCacheOnly].outcome,
                   VibeMetadataReadOutcomeCacheMiss);
    VibeMetadataReadResult *read = [self read:url through:cache policy:VibeMetadataReadPolicyLocal];
    XCTAssertFalse(read.fromCache);
    XCTAssertEqualObjects([read.metadata extraTag:VibeTagFieldCatalogNumber], @"CAT-0042");
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

#pragma mark - A tag-only rewrite

// A tag edit's safe write: a retagged copy, a later modified date, and a
// rename over the original. The audio frames are the same.
static void SafeRetitle(NSURL *url, NSString *title, NSData *_Nullable newArt) {
    NSURL *copy = [url URLByAppendingPathExtension:@"edit.mp3"];
    [NSFileManager.defaultManager removeItemAtURL:copy error:NULL];
    [NSFileManager.defaultManager copyItemAtURL:url toURL:copy error:NULL];
    {
        TagLib::MPEG::File file(copy.fileSystemRepresentation);
        file.ID3v2Tag(true)->setTitle(VibeTagString(title));
        if (newArt) {
            file.ID3v2Tag()->removeFrames("APIC");
            VibeAddAPIC(file.ID3v2Tag(), newArt);
        }
        file.save(TagLib::MPEG::File::ID3v2, TagLib::File::StripOthers, TagLib::ID3v2::v4,
                  TagLib::File::DoNotDuplicate);
    }
    VibePushFileDateForward(copy, 2);
    rename(copy.fileSystemRepresentation, url.fileSystemRepresentation);
}

- (void)moveIn:(AudioTrackMetadataCache *)cache from:(NSString *)oldKey to:(NSString *)newKey
    artChanged:(BOOL)artChanged {
    XCTestExpectation *moved = [self expectationWithDescription:@"moved"];
    [cache moveEntriesOfRetaggedFileFromKey:oldKey toKey:newKey artChanged:artChanged completion:^{
        [moved fulfill];
    }];
    [self waitForExpectations:@[moved] timeout:VIBE_TEST_HANG_TIMEOUT];
}

// After a rewrite, the tags under the old key are gone and the art follows
// the file to its new key. The next read parses the new tags, and a read
// after it hits them.
- (void)testAnEntryAfterARewriteAnswersTheNewTags {
    NSURL *url = [self fileWithArt];
    NSString *root = [_dir URLByAppendingPathComponent:@"cache"].path;
    AudioTrackMetadataCache *cache = [[AudioTrackMetadataCache alloc] initWithRootPath:root];
    NSString *oldKey = [self read:url through:cache policy:VibeMetadataReadPolicyLocal].cacheKey;
    XCTAssertNotNil(oldKey);
    NSData *rendition = (NSData *)[[self store:AudioTrackMetadataCache.displayArtCacheName under:root].diskCache
            objectForKey:oldKey];
    XCTAssertNotNil(rendition);

    SafeRetitle(url, @"Edited Title", nil);
    NSString *newKey = url.cacheKey;
    XCTAssertNotEqualObjects(newKey, oldKey);
    [self moveIn:cache from:oldKey to:newKey artChanged:NO];

    PINCache *tags = [self store:AudioTrackMetadataCache.cacheName under:root];
    PINCache *thumbnails = [self store:AudioTrackMetadataCache.thumbnailCacheName under:root];
    PINCache *displayArt = [self store:AudioTrackMetadataCache.displayArtCacheName under:root];
    XCTAssertNil([tags.diskCache objectForKey:oldKey]);
    XCTAssertNil([tags.diskCache objectForKey:newKey]);
    XCTAssertNil([thumbnails.diskCache objectForKey:oldKey]);
    XCTAssertNotNil([thumbnails.diskCache objectForKey:newKey], @"the thumbnail moved");
    XCTAssertNil([displayArt.diskCache objectForKey:oldKey]);
    XCTAssertEqualObjects([displayArt.diskCache objectForKey:newKey], rendition, @"the rendition moved");

    VibeMetadataReadResult *read = [self read:url through:cache policy:VibeMetadataReadPolicyLocal];
    XCTAssertFalse(read.fromCache);
    XCTAssertEqualObjects(read.cacheKey, newKey);
    XCTAssertEqualObjects(read.metadata.title, @"Edited Title");
    XCTAssertTrue(read.metadata.hasEmbeddedArt);
    VibeMetadataReadResult *hit = [self read:url through:cache policy:VibeMetadataReadPolicyCacheOnly];
    XCTAssertTrue(hit.fromCache);
    XCTAssertEqualObjects(hit.metadata.title, @"Edited Title");
}

// A rewrite that changed the art drops the old art rather than move it, so
// no row draws the old picture under the new key.
- (void)testARewriteOfTheArtDropsTheOldArt {
    NSURL *url = [self fileWithArt];
    NSString *root = [_dir URLByAppendingPathComponent:@"cache"].path;
    AudioTrackMetadataCache *cache = [[AudioTrackMetadataCache alloc] initWithRootPath:root];
    NSString *oldKey = [self read:url through:cache policy:VibeMetadataReadPolicyLocal].cacheKey;
    NSData *blue = VibeImageOfColor(600, 0, 0, 1, YES);
    SafeRetitle(url, @"Edited Title", blue);
    NSString *newKey = url.cacheKey;
    [self moveIn:cache from:oldKey to:newKey artChanged:YES];

    PINCache *thumbnails = [self store:AudioTrackMetadataCache.thumbnailCacheName under:root];
    PINCache *displayArt = [self store:AudioTrackMetadataCache.displayArtCacheName under:root];
    for (NSString *key in @[oldKey, newKey]) {
        XCTAssertNil([thumbnails.diskCache objectForKey:key]);
        XCTAssertNil([displayArt.diskCache objectForKey:key]);
    }
    VibeMetadataReadResult *read = [self read:url through:cache policy:VibeMetadataReadPolicyLocal];
    XCTAssertEqualObjects(read.metadata.title, @"Edited Title");
    XCTAssertEqualObjects([displayArt.diskCache objectForKey:newKey], blue, @"the parse files the new art");
}

// A move of a key with no entries does nothing to the new key's.
- (void)testAMoveOfAnAbsentEntryDoesNothing {
    NSURL *url = [self fileWithArt];
    NSString *root = [_dir URLByAppendingPathComponent:@"cache"].path;
    AudioTrackMetadataCache *cache = [[AudioTrackMetadataCache alloc] initWithRootPath:root];
    NSString *key = [self read:url through:cache policy:VibeMetadataReadPolicyLocal].cacheKey;
    [self moveIn:cache from:@"0-0-absent" to:key artChanged:NO];
    VibeMetadataReadResult *hit = [self read:url through:cache policy:VibeMetadataReadPolicyCacheOnly];
    XCTAssertTrue(hit.fromCache, @"the entry under the new key is kept");
    XCTAssertEqualObjects(hit.metadata.title, kVibeTagTitle);
}

// Different art under both keys: the move keeps the new key's, and the old
// key's goes.
- (void)testAMoveOntoAnEntryKeepsTheNewKeysEntry {
    NSString *root = [_dir URLByAppendingPathComponent:@"cache"].path;
    AudioTrackMetadataCache *cache = [[AudioTrackMetadataCache alloc] initWithRootPath:root];
    [self read:[self fileWithArt] through:cache policy:VibeMetadataReadPolicyCacheOnly];
    NSArray<NSString *> *names = @[AudioTrackMetadataCache.thumbnailCacheName,
                                   AudioTrackMetadataCache.displayArtCacheName];
    for (NSString *name in names) {
        PINCache *store = [self store:name under:root];
        [store.diskCache setObject:[@"old" dataUsingEncoding:NSUTF8StringEncoding] forKey:@"1-1-old"];
        [store.diskCache setObject:[@"new" dataUsingEncoding:NSUTF8StringEncoding] forKey:@"2-2-new"];
    }
    [self moveIn:cache from:@"1-1-old" to:@"2-2-new" artChanged:NO];
    for (NSString *name in names) {
        PINCache *store = [self store:name under:root];
        XCTAssertNil([store.diskCache objectForKey:@"1-1-old"], @"%@", name);
        XCTAssertEqualObjects([store.diskCache objectForKey:@"2-2-new"],
                              [@"new" dataUsingEncoding:NSUTF8StringEncoding], @"%@", name);
    }
}

// A writer that kept the size and the date leaves the key as it was. A
// parse begun before the move, held past it, then files nothing under the
// key, so the next read parses the new tags.
- (void)testEqualKeysKeepAParseInFlightFromFiling {
    NSURL *url = [self fileWithArt];
    NSString *root = [_dir URLByAppendingPathComponent:@"cache"].path;
    AudioTrackMetadataCache *cache = [[AudioTrackMetadataCache alloc] initWithRootPath:root];
    AudioTrackMetadata *oldTags = [AudioTrackMetadata metadataWithURL:url displayArtData:NULL];
    dispatch_semaphore_t entered = dispatch_semaphore_create(0);
    dispatch_semaphore_t gate = dispatch_semaphore_create(0);
    __block NSUInteger parses = 0;
    [cache debugSetReadingFileParser:^AudioTrackMetadata *(NSURL *parsed) {
        if (++parses > 1) {
            return [AudioTrackMetadata metadataWithURL:parsed displayArtData:NULL];
        }
        dispatch_semaphore_signal(entered);
        dispatch_semaphore_wait(gate, dispatch_time(DISPATCH_TIME_NOW,
                                                    (int64_t)(VIBE_TEST_GATE_TIMEOUT * NSEC_PER_SEC)));
        return oldTags;
    }];
    NSString *key = url.cacheKey;
    XCTestExpectation *done = [self expectationWithDescription:@"read"];
    __block VibeMetadataReadResult *held = nil;
    dispatch_queue_t queue = dispatch_queue_create("vibe-libs.tests.metadata-cache.held", DISPATCH_QUEUE_SERIAL);
    [cache readMetadataOfURLs:@[url] policy:VibeMetadataReadPolicyLocal deliveryQueue:queue
                       result:^(VibeMetadataReadResult *result) {
                           held = result;
                       }
                   completion:^{
                       [done fulfill];
                   }];
    XCTAssertEqual(dispatch_semaphore_wait(entered, dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC))), 0);
    [self moveIn:cache from:key to:key artChanged:NO];
    dispatch_semaphore_signal(gate);
    [self waitForExpectations:@[done] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqual(held.outcome, VibeMetadataReadOutcomeRead);

    XCTAssertNil([[self store:AudioTrackMetadataCache.cacheName under:root].diskCache objectForKey:key],
                 @"the held parse filed nothing");
    VibeMetadataReadResult *again = [self read:url through:cache policy:VibeMetadataReadPolicyLocal];
    XCTAssertFalse(again.fromCache);
    XCTAssertEqual(parses, 2u);
}

@end
