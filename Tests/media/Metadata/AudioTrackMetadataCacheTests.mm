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

#pragma mark - The version bump

// An entry filed by the store before the extra tags is never read: the bump
// opens a store of a new name, so the file parses again, and the old store
// is removed with the other versions.
- (void)testTheVersionBumpDiscardsOldEntries {
    NSURL *url = VibeWriteTagFixture(_dir, VibeTagFixtureFLAC, nil, NULL);
    XCTAssertNotNil(url);
    NSString *root = [_dir URLByAppendingPathComponent:@"cache"].path;
    NSString *oldName = @"Audio Track Metadata v10";
    XCTAssertNotEqualObjects(AudioTrackMetadataCache.cacheName, oldName);
    AudioTrackMetadata *parsed = [AudioTrackMetadata metadataWithURL:url displayArtData:NULL];
    PINCache *oldStore = [self store:oldName under:root];
    [oldStore.diskCache setObject:parsed forKey:url.cacheKey];
    XCTAssertNotNil([oldStore.diskCache objectForKey:url.cacheKey]);

    AudioTrackMetadataCache *cache = [[AudioTrackMetadataCache alloc] initWithRootPath:root];
    XCTAssertEqual([self read:url through:cache policy:VibeMetadataReadPolicyCacheOnly].outcome,
                   VibeMetadataReadOutcomeCacheMiss, @"the old store's entry is not read");
    VibeMetadataReadResult *read = [self read:url through:cache policy:VibeMetadataReadPolicyLocal];
    XCTAssertFalse(read.fromCache);
    XCTAssertEqualObjects(read.metadata.catalogNumber, kVibeTagCatalogNumber);

    XCTestExpectation *removed = [self expectationWithDescription:@"removed"];
    [PINCache removeOtherAudioCacheVersionsKeeping:AudioTrackMetadataCache.cacheNames rootPath:root completion:^{
        [removed fulfill];
    }];
    [self waitForExpectations:@[removed] timeout:VIBE_TEST_HANG_TIMEOUT];
    NSString *oldPath = [root stringByAppendingPathComponent:[@"com.pinterest.PINDiskCache." stringByAppendingString:oldName]];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:oldPath]);
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
    NSDate *modified = [[NSFileManager.defaultManager attributesOfItemAtPath:url.path error:NULL] fileModificationDate];
    [NSFileManager.defaultManager setAttributes:@{NSFileModificationDate: [modified dateByAddingTimeInterval:2]}
                                   ofItemAtPath:copy.path error:NULL];
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
// the file to its new key. A held item's memo is retired. The next read
// parses the new tags, and a read after it hits them.
- (void)testAnEntryAfterARewriteAnswersTheNewTags {
    NSURL *url = [self fileWithArt];
    NSString *root = [_dir URLByAppendingPathComponent:@"cache"].path;
    AudioTrackMetadataCache *cache = [[AudioTrackMetadataCache alloc] initWithRootPath:root];
    NSString *oldKey = [self read:url through:cache policy:VibeMetadataReadPolicyLocal].cacheKey;
    XCTAssertNotNil(oldKey);
    VibeLoaderTestTrack *held = [VibeLoaderTestTrack withURL:url];
    XCTAssertEqualObjects(held.cacheKey, oldKey);
    NSData *rendition = (NSData *)[[self store:AudioTrackMetadataCache.displayArtCacheName under:root].diskCache
            objectForKey:oldKey];
    XCTAssertNotNil(rendition);

    SafeRetitle(url, @"Edited Title", nil);
    NSString *newKey = url.cacheKey;
    XCTAssertNotEqualObjects(newKey, oldKey);
    XCTAssertEqualObjects(held.cacheKey, oldKey, @"the memo hides the rewrite until it is retired");
    [self moveIn:cache from:oldKey to:newKey artChanged:NO];
    XCTAssertEqualObjects(held.cacheKey, newKey, @"the move retires every memo");

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

// A move of a key with no entries does nothing, and an entry the new key
// already holds is kept.
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

@end
