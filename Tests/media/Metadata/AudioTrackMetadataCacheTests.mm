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
#import "AudioTrackMetadataCacheInternal.h"
#import "AudioTrackMetadataInternal.h"
#import "AudioTrackMetadataTagFixtures.h"
#import "ImageFixtures.h"
#import "PlatformImage.h"
#import "MetadataLoaderTestFakes.h"
#import "NSURL+Hash.h"
#import "VibeTestFileDates.h"
#import "AudioTrackMetadataCache+Debug.h"
#import "PINCache+VibeAudioCache.h"
#import "VibeMetadataImport.h"
#import "VibeMetadataStore.h"
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
    [VibeMetadataImport setStartDelayForTesting:10];
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
    SEL selector = @selector(checkOutStoreUnderRootPath:);
    Method method = class_getClassMethod(VibeMetadataStore.class, selector);
    IMP original = method_getImplementation(method);
    IMP held = imp_implementationWithBlock(^VibeMetadataStore *(Class cls, NSString *rootPath) {
        dispatch_semaphore_signal(building);
        dispatch_semaphore_wait(gate, dispatch_time(DISPATCH_TIME_NOW,
                                                    (int64_t)(VIBE_TEST_GATE_TIMEOUT * NSEC_PER_SEC)));
        VibeMetadataStore *store = ((VibeMetadataStore *(*)(Class, SEL, NSString *))original)(cls, selector,
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

#pragma mark - Art by its picture

// A tagged file with a picture of the rendition's size, so the rendition is
// the picture's bytes.
- (NSURL *)fileWithArt {
    NSURL *url = VibeWriteTagFixture(_dir, VibeTagFixtureMP3ID3v24, VibeImageOfColor(600, 1, 0, 0, UTTypeJPEG), NULL);
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

// One of the PINCache stores of the releases before, opened as they were.
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

// The tags' entry for the file under key, as the store holds it.
- (nullable AudioTrackMetadata *)filedTagsIn:(AudioTrackMetadataCache *)cache key:(NSString *)key {
    VibeCacheHit *hit = [cache.metadataCache tagsHitForKey:key acceptingOlder:YES];
    return hit ? VibeMetadataUnarchive(hit.data, AudioTrackMetadata.class) : nil;
}

// The name of the picture the entry under key names.
- (nullable NSString *)pictureIn:(AudioTrackMetadataCache *)cache key:(NSString *)key {
    return [cache.metadataCache.cacheStore hitForKey:key acceptingFormatsUpTo:VibeMetadataTagsFormat].sharedName;
}

// The tags go in the file's entry, and the thumbnail and the rendition in
// its picture, named by the SHA-256 of the picture's bytes (CH8).
- (void)testArtIsFiledUnderItsPicture {
    NSURL *url = [self fileWithArt];
    NSString *root = [_dir URLByAppendingPathComponent:@"cache"].path;
    AudioTrackMetadataCache *cache = [[AudioTrackMetadataCache alloc] initWithRootPath:root];
    VibeMetadataReadResult *answer = [self read:url through:cache policy:VibeMetadataReadPolicyLocal];
    XCTAssertEqual(answer.outcome, VibeMetadataReadOutcomeRead);
    XCTAssertFalse(answer.fromCache);
    NSString *key = answer.cacheKey;
    XCTAssertNotNil(key);

    AudioTrackMetadata *filed = [self filedTagsIn:cache key:key];
    XCTAssertEqualObjects(filed.title, kVibeTagTitle);
    XCTAssertTrue(filed.artwork.hasEmbeddedArt, @"the entry says the file has art");
    XCTAssertNil(filed.artwork.encodedThumbnailDataForStorage, @"the entry holds no art");
    NSData *picture = VibeImageOfColor(600, 1, 0, 0, UTTypeJPEG);
    NSString *name = [self pictureIn:cache key:key];
    XCTAssertEqualObjects(name, [VibeMetadataStore nameOfPictureWithDigest:picture.sha256Digest]);
    NSData *thumbnail = [cache.metadataCache thumbnailOfPicture:name];
    CGSize size = VibeEncodedImagePixelSize(thumbnail);
    XCTAssertEqual(MAX(size.width, size.height), kVibeThumbnailArtDimension);
    XCTAssertEqualObjects([cache.metadataCache renditionOfPicture:name], picture);
}

// A hit holds no art bytes. Its row thumbnail decodes from the picture's
// thumbnail, with the rendition gone, and never reads the file.
- (void)testAHitDecodesItsThumbnailFromThePicturesThumbnail {
    NSURL *url = [self fileWithArt];
    NSString *root = [_dir URLByAppendingPathComponent:@"cache"].path;
    AudioTrackMetadataCache *cache = [[AudioTrackMetadataCache alloc] initWithRootPath:root];
    NSString *key = [self read:url through:cache policy:VibeMetadataReadPolicyLocal].cacheKey;
    [cache.metadataCache.cacheStore removeSharedItemForName:[self pictureIn:cache key:key]
                                                       part:VibeMetadataStore.renditionPart];

    AudioTrackMetadataCache *reopened = [[AudioTrackMetadataCache alloc] initWithRootPath:root];
    VibeMetadataReadResult *hit = [self read:url through:reopened policy:VibeMetadataReadPolicyCacheOnly];
    XCTAssertEqual(hit.outcome, VibeMetadataReadOutcomeRead);
    XCTAssertTrue(hit.fromCache);
    XCTAssertNil(hit.metadata.artwork.encodedThumbnailDataForStorage);
    NSImage *thumbnail = [self thumbnailOf:hit.metadata];
    XCTAssertNotNil(thumbnail, @"the picture's thumbnail");
    XCTAssertNotNil(hit.metadata.artwork.archivedThumbnailProvider, @"a read that found bytes keeps its provider");
}

// A hit whose thumbnail was evicted decodes it from the rendition, and drops
// the provider that read nothing.
- (void)testAHitWhoseThumbnailIsGoneDecodesFromTheRendition {
    NSURL *url = [self fileWithArt];
    NSString *root = [_dir URLByAppendingPathComponent:@"cache"].path;
    AudioTrackMetadataCache *cache = [[AudioTrackMetadataCache alloc] initWithRootPath:root];
    NSString *key = [self read:url through:cache policy:VibeMetadataReadPolicyLocal].cacheKey;
    [cache.metadataCache.cacheStore removeSharedItemForName:[self pictureIn:cache key:key]
                                                       part:VibeMetadataStore.thumbnailPart];

    AudioTrackMetadataCache *reopened = [[AudioTrackMetadataCache alloc] initWithRootPath:root];
    VibeMetadataReadResult *hit = [self read:url through:reopened policy:VibeMetadataReadPolicyCacheOnly];
    XCTAssertTrue(hit.fromCache);
    XCTAssertNotNil([self thumbnailOf:hit.metadata], @"the rendition stands in");
    XCTAssertNil(hit.metadata.artwork.archivedThumbnailProvider);
}

// An app sets each budget over the defaults. The one store's byte limit is
// their sum, and its age limit the longest. A budget it sets nothing for
// keeps the defaults.
- (void)testAnAppSetsEachStoresLimits {
    NSString *root = [_dir URLByAppendingPathComponent:@"cache"].path;
    AudioTrackMetadataCache *cache = [[AudioTrackMetadataCache alloc] initWithRootPath:root];
    VibeCacheStore *store = cache.metadataCache.cacheStore;
    XCTAssertEqual(store.byteLimit, 3 * VibeCacheStore.defaultByteLimit, @"an app that sets nothing");
    XCTAssertEqual(store.ageLimit, VibeCacheStore.defaultAgeLimit);
    [cache setByteLimit:3 * 1024 * 1024 ageLimit:30 * 86400.0 forStore:VibeMetadataCacheStoreThumbnails];
    [cache setByteLimit:4 * 1024 * 1024 ageLimit:60 * 86400.0 forStore:VibeMetadataCacheStoreDisplayArt];
    // The setters run on the cache's queue, which the usage count runs after.
    void (^settle)(void) = ^{
        XCTestExpectation *counted = [self expectationWithDescription:@"counted"];
        [cache diskUsageWithCompletion:^(NSUInteger fileCount, unsigned long long totalBytes) {
            [counted fulfill];
        }];
        [self waitForExpectations:@[counted] timeout:VIBE_TEST_HANG_TIMEOUT];
    };
    settle();
    XCTAssertEqual(store.byteLimit, VibeCacheStore.defaultByteLimit + 7u * 1024 * 1024);
    XCTAssertEqual(store.ageLimit, VibeCacheStore.defaultAgeLimit, @"the tags' default is the longest");
    [cache setByteLimit:5 * 1024 * 1024 ageLimit:90 * 86400.0 forStore:VibeMetadataCacheStoreTags];
    settle();
    XCTAssertEqual(store.byteLimit, 12u * 1024 * 1024);
    XCTAssertEqual(store.ageLimit, 90 * 86400.0);
    [cache setByteLimit:0 ageLimit:0 forStore:VibeMetadataCacheStoreTags];
    settle();
    XCTAssertEqual(store.byteLimit, 0u, @"a budget of none lifts the store's limit");
    XCTAssertEqual(store.ageLimit, 0.0);
}

// The disk usage counts the entry and the picture's two parts, and an
// invalidation empties the store.
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
    NSString *picture = [self pictureIn:cache key:oldKey];
    NSData *rendition = [cache.metadataCache renditionOfPicture:picture];
    XCTAssertNotNil(rendition);
    VibeCacheUsage before = cache.metadataCache.usage;

    SafeRetitle(url, @"Edited Title", nil);
    NSString *newKey = url.cacheKey;
    XCTAssertNotEqualObjects(newKey, oldKey);
    [self moveIn:cache from:oldKey to:newKey artChanged:NO];

    XCTAssertNil([self filedTagsIn:cache key:oldKey]);
    XCTAssertNil([self filedTagsIn:cache key:newKey], @"the tags were dropped");
    XCTAssertFalse([cache.metadataCache.cacheStore hasEntryForKey:oldKey]);
    XCTAssertEqualObjects([self pictureIn:cache key:newKey], picture, @"the new key names the same picture");
    XCTAssertNotNil([cache.metadataCache thumbnailOfPicture:picture], @"the thumbnail stayed");
    XCTAssertEqualObjects([cache.metadataCache renditionOfPicture:picture], rendition, @"the rendition stayed");
    VibeCacheUsage after = cache.metadataCache.usage;
    XCTAssertEqual(after.entries, before.entries);
    XCTAssertEqual(after.sharedItems, before.sharedItems, @"no art moved or was written");

    VibeMetadataReadResult *read = [self read:url through:cache policy:VibeMetadataReadPolicyLocal];
    XCTAssertFalse(read.fromCache);
    XCTAssertEqualObjects(read.cacheKey, newKey);
    XCTAssertEqualObjects(read.metadata.title, @"Edited Title");
    XCTAssertTrue(read.metadata.hasEmbeddedArt);
    VibeMetadataReadResult *hit = [self read:url through:cache policy:VibeMetadataReadPolicyCacheOnly];
    XCTAssertTrue(hit.fromCache);
    XCTAssertEqualObjects(hit.metadata.title, @"Edited Title");
    XCTAssertEqualObjects([self pictureIn:cache key:newKey], picture);
}

// A rewrite that changed the art drops the old art rather than move it, so
// no row draws the old picture under the new key.
- (void)testARewriteOfTheArtDropsTheOldArt {
    NSURL *url = [self fileWithArt];
    NSString *root = [_dir URLByAppendingPathComponent:@"cache"].path;
    AudioTrackMetadataCache *cache = [[AudioTrackMetadataCache alloc] initWithRootPath:root];
    NSString *oldKey = [self read:url through:cache policy:VibeMetadataReadPolicyLocal].cacheKey;
    NSString *red = [self pictureIn:cache key:oldKey];
    NSData *blue = VibeImageOfColor(600, 0, 0, 1, UTTypeJPEG);
    SafeRetitle(url, @"Edited Title", blue);
    NSString *newKey = url.cacheKey;
    [self moveIn:cache from:oldKey to:newKey artChanged:YES];

    for (NSString *key in @[oldKey, newKey]) {
        XCTAssertFalse([cache.metadataCache.cacheStore hasEntryForKey:key]);
    }
    XCTAssertNil([cache.metadataCache thumbnailOfPicture:red], @"no entry names the old picture, so it went");
    XCTAssertNil([cache.metadataCache renditionOfPicture:red]);
    VibeMetadataReadResult *read = [self read:url through:cache policy:VibeMetadataReadPolicyLocal];
    XCTAssertEqualObjects(read.metadata.title, @"Edited Title");
    XCTAssertEqualObjects([cache.metadataCache renditionOfPicture:[self pictureIn:cache key:newKey]], blue,
                          @"the parse files the new art");
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

// Different art under both keys: the move keeps the new key's entry, and
// the old key's goes, with the picture no entry names any more.
- (void)testAMoveOntoAnEntryKeepsTheNewKeysEntry {
    NSString *root = [_dir URLByAppendingPathComponent:@"cache"].path;
    AudioTrackMetadataCache *cache = [[AudioTrackMetadataCache alloc] initWithRootPath:root];
    VibeMetadataStore *store = cache.metadataCache;
    NSData *older = [@"old" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *newer = [@"new" dataUsingEncoding:NSUTF8StringEncoding];
    NSString *oldPicture = [store fileTags:@"old tags" thumbnail:older rendition:older pictureName:@"old-picture"
                                    forKey:@"1-1-old"];
    NSString *newPicture = [store fileTags:@"new tags" thumbnail:newer rendition:newer pictureName:@"new-picture"
                                    forKey:@"2-2-new"];
    [self moveIn:cache from:@"1-1-old" to:@"2-2-new" artChanged:NO];
    XCTAssertFalse([store.cacheStore hasEntryForKey:@"1-1-old"]);
    XCTAssertNil([store thumbnailOfPicture:oldPicture]);
    XCTAssertNil([store renditionOfPicture:oldPicture]);
    XCTAssertEqualObjects(VibeMetadataUnarchive([store tagsHitForKey:@"2-2-new" acceptingOlder:NO].data,
                                                NSString.class), @"new tags");
    XCTAssertEqualObjects([self pictureIn:cache key:@"2-2-new"], newPicture);
    XCTAssertEqualObjects([store thumbnailOfPicture:newPicture], newer);
    XCTAssertEqualObjects([store renditionOfPicture:newPicture], newer);
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

    XCTAssertNil([self filedTagsIn:cache key:key], @"the held parse filed nothing");
    VibeMetadataReadResult *again = [self read:url through:cache policy:VibeMetadataReadPolicyLocal];
    XCTAssertFalse(again.fromCache);
    XCTAssertEqual(parses, 2u);
}

#pragma mark - Formats

// The file's tags as a row of the format before the current one, under its
// key, as a store keeps them after a format bump.
- (NSString *)fileOlderRowOf:(NSURL *)url in:(AudioTrackMetadataCache *)cache {
    NSString *key = url.cacheKey;
    AudioTrackMetadata *tags = [AudioTrackMetadata metadataWithURL:url displayArtData:NULL];
    [cache.metadataCache.cacheStore setData:VibeMetadataArchive(tags) forKey:key
                                     format:VibeMetadataTagsFormat - 1 sharedName:nil];
    return key;
}

// An older row is a miss for a read that may open the file, which parses it
// and replaces the row (CH16).
- (void)testAnOlderRowIsAMissForAReadThatMayOpenTheFile {
    NSURL *url = VibeWriteTagFixture(_dir, VibeTagFixtureFLAC, nil, NULL);
    AudioTrackMetadataCache *cache =
            [[AudioTrackMetadataCache alloc] initWithRootPath:[_dir URLByAppendingPathComponent:@"cache"].path];
    NSString *key = [self fileOlderRowOf:url in:cache];
    VibeMetadataReadResult *read = [self read:url through:cache policy:VibeMetadataReadPolicyLocal];
    XCTAssertEqual(read.outcome, VibeMetadataReadOutcomeRead);
    XCTAssertFalse(read.fromCache, @"the older row was not read");
    XCTAssertFalse(read.older);
    XCTAssertEqualObjects(read.metadata.cacheKey, key);
    XCTAssertEqual([cache.metadataCache.cacheStore hitForKey:key acceptingFormatsUpTo:VibeMetadataTagsFormat].format,
                   VibeMetadataTagsFormat, @"the parse replaced the row");
}

// A read that may not open the file answers from an older row, marked older,
// with no version, so the fields it lacks are unknown (CH17).
- (void)testAnOlderRowAnswersACacheOnlyReadMarkedOlder {
    NSURL *url = VibeWriteTagFixture(_dir, VibeTagFixtureFLAC, nil, NULL);
    AudioTrackMetadataCache *cache =
            [[AudioTrackMetadataCache alloc] initWithRootPath:[_dir URLByAppendingPathComponent:@"cache"].path];
    NSString *key = [self fileOlderRowOf:url in:cache];
    VibeMetadataReadResult *read = [self read:url through:cache policy:VibeMetadataReadPolicyCacheOnly];
    XCTAssertEqual(read.outcome, VibeMetadataReadOutcomeRead);
    XCTAssertTrue(read.fromCache);
    XCTAssertTrue(read.older);
    XCTAssertEqualObjects(read.cacheKey, key, @"the result names the version it looked up");
    XCTAssertTrue(read.metadata.olderFormat);
    XCTAssertNil(read.metadata.cacheKey, @"the answer names no version");
    XCTAssertEqualObjects(read.metadata.title, kVibeTagTitle);
}

// A row's older answer is installed by a cache-only load, and the next load
// that may open the file replaces it in the holder.
- (void)testAHolderTakesTheNextAnswerInPlaceOfAnOlderOne {
    NSURL *url = VibeWriteTagFixture(_dir, VibeTagFixtureFLAC, nil, NULL);
    AudioTrackMetadataCache *cache =
            [[AudioTrackMetadataCache alloc] initWithRootPath:[_dir URLByAppendingPathComponent:@"cache"].path];
    NSString *key = [self fileOlderRowOf:url in:cache];
    VibeMetadataLoaderDelegate *delegate = [[VibeMetadataLoaderDelegate alloc] init];
    cache.delegate = delegate;
    VibeLoaderTestTrack *track = [VibeLoaderTestTrack withURL:url];
    [cache loadCachedMetadata:@[track]];
    XCTAssertTrue([self waitFor:^BOOL { return delegate.deliveredTracks.count > 0; } within:VIBE_TEST_HANG_TIMEOUT]);
    XCTAssertTrue(track.metadata.olderFormat);
    XCTAssertEqualObjects(track.metadata.title, kVibeTagTitle);

    [cache loadMetadata:@[track]];
    XCTAssertTrue([self waitFor:^BOOL { return delegate.deliveredTracks.count > 1; } within:VIBE_TEST_HANG_TIMEOUT],
                  @"the parse replaced the older answer");
    XCTAssertFalse(track.metadata.olderFormat);
    XCTAssertEqualObjects(track.metadata.cacheKey, key);
    XCTAssertEqualObjects([track.metadata extraTag:VibeTagFieldCatalogNumber], @"CAT-0042");
    cache.delegate = nil;
}

#pragma mark - One copy of each picture

// Two files that embed one picture keep one thumbnail and one rendition.
- (void)testFilesThatEmbedOnePictureKeepOneCopy {
    NSData *red = VibeImageOfColor(600, 1, 0, 0, UTTypeJPEG);
    NSURL *first = VibeWriteTagFixture(_dir, VibeTagFixtureMP3ID3v24, red, NULL);
    NSURL *second = VibeWriteTagFixture(_dir, VibeTagFixtureMP3ID3v23, red, NULL);
    AudioTrackMetadataCache *cache =
            [[AudioTrackMetadataCache alloc] initWithRootPath:[_dir URLByAppendingPathComponent:@"cache"].path];
    NSString *firstKey = [self read:first through:cache policy:VibeMetadataReadPolicyLocal].cacheKey;
    NSString *secondKey = [self read:second through:cache policy:VibeMetadataReadPolicyLocal].cacheKey;
    XCTAssertEqualObjects([self pictureIn:cache key:firstKey], [self pictureIn:cache key:secondKey]);
    VibeCacheUsage usage = cache.metadataCache.usage;
    XCTAssertEqual(usage.entries, 2u);
    XCTAssertEqual(usage.sharedItems, 2u, @"one thumbnail and one rendition");
    for (NSURL *url in @[first, second]) {
        VibeMetadataReadResult *hit = [self read:url through:cache policy:VibeMetadataReadPolicyCacheOnly];
        XCTAssertTrue(hit.fromCache);
        XCTAssertNotNil([self thumbnailOf:hit.metadata]);
    }
}

// A picture stays while an entry names it, and goes with the last (CH11).
// Its entries then read as art that is not cached.
- (void)testAPictureGoesWhenNoEntryNamesIt {
    NSData *red = VibeImageOfColor(600, 1, 0, 0, UTTypeJPEG);
    NSURL *first = VibeWriteTagFixture(_dir, VibeTagFixtureMP3ID3v24, red, NULL);
    NSURL *second = VibeWriteTagFixture(_dir, VibeTagFixtureMP3ID3v23, red, NULL);
    AudioTrackMetadataCache *cache =
            [[AudioTrackMetadataCache alloc] initWithRootPath:[_dir URLByAppendingPathComponent:@"cache"].path];
    NSString *firstKey = [self read:first through:cache policy:VibeMetadataReadPolicyLocal].cacheKey;
    NSString *secondKey = [self read:second through:cache policy:VibeMetadataReadPolicyLocal].cacheKey;
    NSString *picture = [self pictureIn:cache key:firstKey];
    VibeMetadataStore *store = cache.metadataCache;
    [store removeEntryForKey:firstKey];
    XCTAssertNotNil([store renditionOfPicture:picture], @"the second file still names it");
    [store.cacheStore removeSharedItemForName:picture part:VibeMetadataStore.thumbnailPart];
    VibeMetadataReadResult *hit = [self read:second through:cache policy:VibeMetadataReadPolicyCacheOnly];
    XCTAssertTrue(hit.metadata.hasEmbeddedArt);
    XCTAssertNotNil([self thumbnailOf:hit.metadata], @"a trimmed thumbnail decodes from the rendition");
    [store removeEntryForKey:secondKey];
    XCTAssertNil([store renditionOfPicture:picture]);
    XCTAssertEqual(store.usage.sharedItems, 0u);
}

#pragma mark - The import

// The PINCache stores of the releases before, filled as their cache filed a
// parse: the tags under the file's key, and its thumbnail and rendition each
// in its own store under the same key. Two files embed one picture, and one
// embeds none.
- (NSArray<NSURL *> *)fillOldStoresUnder:(NSString *)root {
    NSData *red = VibeImageOfColor(600, 1, 0, 0, UTTypeJPEG);
    NSArray<NSURL *> *urls = @[VibeWriteTagFixture(_dir, VibeTagFixtureMP3ID3v24, red, NULL),
                               VibeWriteTagFixture(_dir, VibeTagFixtureMP3ID3v23, red, NULL),
                               VibeWriteTagFixture(_dir, VibeTagFixtureWAVID3, nil, NULL)];
    NSArray<NSString *> *names = VibeMetadataImport.oldStoreNames;
    @autoreleasepool {
        PINCache *tags = [self store:names[0] under:root];
        PINCache *thumbnails = [self store:names[1] under:root];
        PINCache *renditions = [self store:names[2] under:root];
        for (NSURL *url in urls) {
            NSData *rendition = nil;
            AudioTrackMetadata *metadata = [AudioTrackMetadata metadataWithURL:url displayArtData:&rendition];
            [tags.diskCache setObject:metadata forKey:url.cacheKey];
            NSData *thumbnail = metadata.artwork.encodedThumbnailDataForStorage;
            if (thumbnail) {
                [thumbnails.diskCache setObject:thumbnail forKey:url.cacheKey];
            }
            if (rendition) {
                [renditions.diskCache setObject:rendition forKey:url.cacheKey];
            }
        }
    }
    return urls;
}

- (BOOL)oldStoresAreUnder:(NSString *)root {
    for (NSString *name in VibeMetadataImport.oldStoreNames) {
        NSString *folder = [root stringByAppendingPathComponent:[@"com.pinterest.PINDiskCache." stringByAppendingString:name]];
        if ([NSFileManager.defaultManager fileExistsAtPath:folder]) {
            return YES;
        }
    }
    return NO;
}

- (void)waitForTheImportOf:(VibeMetadataStore *)store {
    XCTestExpectation *imported = [self expectationWithDescription:@"imported"];
    [store performAfterImportForTesting:^{
        [imported fulfill];
    }];
    [self waitForExpectations:@[imported] timeout:VIBE_TEST_HANG_TIMEOUT];
}

// Every entry of each old store reads back the same, the files that embed
// one picture keep one copy of it, and the old stores are gone at the end.
- (void)testTheImportBringsEveryEntryOverThenRemovesTheOldStores {
    NSString *root = [_dir URLByAppendingPathComponent:@"cache"].path;
    NSArray<NSURL *> *urls = [self fillOldStoresUnder:root];
    [VibeMetadataImport setStartDelayForTesting:0];
    AudioTrackMetadataCache *cache = [[AudioTrackMetadataCache alloc] initWithRootPath:root];
    [self waitForTheImportOf:cache.metadataCache];
    XCTAssertFalse([self oldStoresAreUnder:root]);
    VibeCacheUsage usage = cache.metadataCache.usage;
    XCTAssertEqual(usage.entries, 3u);
    XCTAssertEqual(usage.sharedItems, 2u, @"one picture's thumbnail and rendition");
    NSData *red = VibeImageOfColor(600, 1, 0, 0, UTTypeJPEG);
    for (NSURL *url in urls) {
        VibeMetadataReadResult *hit = [self read:url through:cache policy:VibeMetadataReadPolicyCacheOnly];
        XCTAssertEqual(hit.outcome, VibeMetadataReadOutcomeRead, @"%@", url.lastPathComponent);
        XCTAssertTrue(hit.fromCache);
        XCTAssertFalse(hit.older);
        XCTAssertEqualObjects(hit.metadata.title, kVibeTagTitle);
        XCTAssertEqualObjects(hit.metadata.album, [AudioTrackMetadata metadataWithURL:url displayArtData:NULL].album);
        if (url != urls.lastObject) {
            XCTAssertTrue(hit.metadata.hasEmbeddedArt);
            XCTAssertEqualObjects([cache.metadataCache renditionOfPicture:[self pictureIn:cache key:hit.cacheKey]], red);
            XCTAssertNotNil([self thumbnailOf:hit.metadata]);
        } else {
            XCTAssertFalse(hit.metadata.hasEmbeddedArt);
            XCTAssertNil([self pictureIn:cache key:hit.cacheKey]);
        }
    }
}

// A miss before the import reaches its entry looks in the old store, and
// brings the entry over, so the file is not parsed.
- (void)testAMissDuringTheImportFindsTheOldEntry {
    NSString *root = [_dir URLByAppendingPathComponent:@"cache"].path;
    NSArray<NSURL *> *urls = [self fillOldStoresUnder:root];
    [VibeMetadataImport setStartDelayForTesting:-1];
    AudioTrackMetadataCache *cache = [[AudioTrackMetadataCache alloc] initWithRootPath:root];
    __block NSUInteger parses = 0;
    [cache debugSetReadingFileParser:^AudioTrackMetadata *(NSURL *url) {
        parses++;
        return [AudioTrackMetadata metadataWithURL:url displayArtData:NULL];
    }];
    VibeMetadataReadResult *hit = [self read:urls.firstObject through:cache policy:VibeMetadataReadPolicyLocal];
    XCTAssertTrue(hit.fromCache);
    XCTAssertEqual(parses, 0u);
    XCTAssertEqualObjects(hit.metadata.title, kVibeTagTitle);
    XCTAssertNotNil([self thumbnailOf:hit.metadata]);
    XCTAssertEqual(cache.metadataCache.usage.entries, 1u);
    XCTAssertTrue([self oldStoresAreUnder:root], @"the bulk import has not run");
}

// An import cut short goes on at the next open, past what it brought over.
- (void)testAnImportCutShortGoesOnAtTheNextOpen {
    NSString *root = [_dir URLByAppendingPathComponent:@"cache"].path;
    NSArray<NSURL *> *urls = [self fillOldStoresUnder:root];
    [VibeMetadataImport setStartDelayForTesting:-1];
    VibeMetadataStore *first = [VibeMetadataStore checkOutStoreUnderRootPath:root];
    XCTAssertNotNil([first tagsHitForKey:urls.firstObject.cacheKey acceptingOlder:NO]);
    [first checkIn];
    XCTAssertTrue([self oldStoresAreUnder:root]);

    [VibeMetadataImport setStartDelayForTesting:0];
    VibeMetadataStore *second = [VibeMetadataStore checkOutStoreUnderRootPath:root];
    XCTAssertNotEqual(first, second, @"the first closed");
    [self waitForTheImportOf:second];
    XCTAssertEqual(second.usage.entries, 3u);
    XCTAssertFalse([self oldStoresAreUnder:root]);
    [second checkIn];
}

// A Clear during the import removes the old stores too, so nothing comes
// back from them.
- (void)testAClearDuringTheImportRemovesTheOldStores {
    NSString *root = [_dir URLByAppendingPathComponent:@"cache"].path;
    NSArray<NSURL *> *urls = [self fillOldStoresUnder:root];
    [VibeMetadataImport setStartDelayForTesting:-1];
    AudioTrackMetadataCache *cache = [[AudioTrackMetadataCache alloc] initWithRootPath:root];
    XCTestExpectation *emptied = [self expectationWithDescription:@"emptied"];
    [cache invalidateWithCompletion:^{
        [emptied fulfill];
    }];
    [self waitForExpectations:@[emptied] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertFalse([self oldStoresAreUnder:root]);
    XCTAssertEqual([self read:urls.firstObject through:cache policy:VibeMetadataReadPolicyCacheOnly].outcome,
                   VibeMetadataReadOutcomeCacheMiss);
}

@end
