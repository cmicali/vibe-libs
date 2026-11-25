//
//  AudioTrackMetadataLoader+Parse.m
//  vibe-libs
//
//  Stage 2 and the cache: the disk-cache read, the parse and its cache write,
//  installation, settlement and publication, and the art's two stores: the
//  row thumbnail and the display-art rendition.
//

#import "AudioTrackMetadataLoaderInternal.h"
#import "AudioTrackMetadataCacheInternal.h"
#import "VibeMetadataStore.h"
#import "AudioTrackMetadata.h"
#import "AudioTrackMetadataInternal.h"
#import "AudioTrackArtwork.h"
#import "MetadataScanEntry.h"
#import "MetadataParseCoordinator.h"
#import "HelperMacros.h"
#import "VibeMacros.h"

#import "AudioTrackMetadataLoader+Debug.h"

// A blocking read of one part of a picture, on a worker. A departed store
// reads as absent.
static AudioTrackArchivedArtProvider VibeArchivedArtReader(VibeMetadataStore *store, NSString *picture,
                                                           BOOL rendition) {
    __weak VibeMetadataStore *weakStore = store;
    return ^NSData *{
        VibeMetadataStore *strongStore = weakStore;
        return rendition ? [strongStore renditionOfPicture:picture] : [strongStore thumbnailOfPicture:picture];
    };
}

// An art-bearing entry's thumbnail and rendition are its picture's, which
// every file that embeds it shares. The thumbnail decodes from its part, then
// from the rendition. An absent rendition falls through to source extraction
// for full art. An entry that names no picture gets neither.
static void VibeInstallArchivedArtProviders(AudioTrackMetadata *metadata,
                                            VibeMetadataStore *store,
                                            NSString *_Nullable picture) {
    if (!picture || !metadata.artwork.hasEmbeddedArt) {
        return;
    }
    metadata.artwork.archivedThumbnailProvider = VibeArchivedArtReader(store, picture, NO);
    metadata.artwork.archivedDisplayArtProvider = VibeArchivedArtReader(store, picture, YES);
}

@implementation AudioTrackMetadataLoader (Parse)

// Reads file attributes and the cache, never the audio bytes. A dataless
// file needs no download for this lookup.
- (AudioTrackMetadata *)readCachedMetadataForTrack:(id<AudioTrackMetadataHolder>)track
                                    acceptingOlder:(BOOL)acceptingOlder {
    if (_cacheReader) {
        return _cacheReader(track);
    }
    // nil when the stat fails (NSURL+Hash); the parse still runs.
    NSString *cacheKey = track.cacheKey;
    if (!cacheKey) {
        LogWarn(@"No cache key for %@ — loading metadata uncached", track.url.path);
        return nil;
    }
    return [self cachedMetadataForKey:cacheKey url:track.url acceptingOlder:acceptingOlder];
}

- (nullable AudioTrackMetadata *)cachedMetadataForKey:(NSString *)cacheKey
                                                  url:(nullable NSURL *)url
                                       acceptingOlder:(BOOL)acceptingOlder {
    VibeMetadataStore *store = _owner.metadataCache;
    VibeCacheHit *hit = [store tagsHitForKey:cacheKey url:url acceptingOlder:acceptingOlder];
    if (!hit) {
        return nil;
    }
    // A wrong root class, or an archive initWithCoder: refuses, goes, so it
    // is not read again every launch.
    AudioTrackMetadata *cachedMetaData = VibeMetadataUnarchive(hit.data, AudioTrackMetadata.class);
    if (!cachedMetaData) {
        [store removeEntryForKey:cacheKey];
        return nil;
    }
    // The art reads the file where it is now, not where the entry's parse
    // found it (AudioTrackArtwork.h). With no URL it reads nothing.
    NSString *path = url.path;
    if (path) {
        [cachedMetaData.artwork adoptSourceFilePath:path];
    }
    // CH17: an older row's answer names no version, so a holder takes the
    // next answer in its place.
    if (hit.older) {
        [cachedMetaData setOlderFormat:YES];
    } else {
        [cachedMetaData setCacheKey:cacheKey];
    }
    VibeInstallArchivedArtProviders(cachedMetaData, store, hit.sharedName);
    return cachedMetaData;
}

- (void)loadFromCacheOnly:(NSArray<id<AudioTrackMetadataHolder>> *)tracks {
    __weak __typeof(self) weakSelf = self;
    for (id<AudioTrackMetadataHolder> track in tracks) {
        NSOperation *op = [NSBlockOperation blockOperationWithBlock:^{
            __typeof(self) strongSelf = weakSelf;
            if (strongSelf && !track.metadata) {
                // It never opens the file, so an older row answers (CH17).
                [strongSelf loadTrackFromDiskCache:track acceptingOlder:YES];
            }
        }];
        // Rows on screen.
        op.qualityOfService = NSQualityOfServiceUserInitiated;
        op.queuePriority = NSOperationQueuePriorityHigh;
        [_queue addOperation:op];
    }
}

// A successful answer read from the version the item's key names now. A
// download that installed another version moves the key, so the row is
// parsed again.
- (BOOL)holdsCurrentMetadata:(id<AudioTrackMetadataHolder>)track {
    AudioTrackMetadata *metadata = track.metadata;
    if (!VibeMetadataIsSettled(metadata)) {
        return NO;
    }
    NSString *cacheKey = track.cacheKey;
    return metadata.cacheKey == cacheKey || [metadata.cacheKey isEqualToString:cacheKey];
}

- (BOOL)loadTrackFromDiskCache:(id<AudioTrackMetadataHolder>)track {
    // The sweep may open the file, so an older row is a miss (CH16).
    return [self loadTrackFromDiskCache:track acceptingOlder:NO];
}

- (BOOL)loadTrackFromDiskCache:(id<AudioTrackMetadataHolder>)track acceptingOlder:(BOOL)acceptingOlder {
    AudioTrackMetadata *cachedMetaData = [self readCachedMetadataForTrack:track acceptingOlder:acceptingOlder];
    if (!cachedMetaData) {
        return NO;
    }
    // Only the winner publishes: another lane may have installed a parse
    // during the read.
    if ([track installMetadataIfUnresolved:cachedMetaData]) {
        [self publishTrack:track];
    }
    return YES;
}

// Stage 2's one parse operation for a Ready record, user-initiated for the
// current track. Answers whether it went user-initiated.
- (BOOL)scheduleParseForEntry:(MetadataScanEntry *)entry
                userInitiated:(BOOL)userInitiatedParse {
    __weak __typeof(self) weakSelf = self;
    __block __weak NSOperation *weakParse = nil;
    NSOperation *parse = [NSBlockOperation blockOperationWithBlock:^{
        __typeof(self) strongSelf = weakSelf;
        if (strongSelf) {
            BOOL readAnotherVersion = !strongSelf.isCancelled && [strongSelf parseOneEntry:entry];
            [strongSelf finishParseOperation:weakParse forEntry:entry];
            if (readAnotherVersion) {
                [strongSelf scheduleParseForEntry:entry
                                    userInitiated:weakParse.qualityOfService
                                                  == NSQualityOfServiceUserInitiated];
            }
        }
    }];
    weakParse = parse;
    parse.qualityOfService = userInitiatedParse
            ? NSQualityOfServiceUserInitiated : NSQualityOfServiceUtility;
    if (userInitiatedParse) {
        parse.queuePriority = NSOperationQueuePriorityHigh;
    }
    os_unfair_lock_lock(&_materializationLock);
    // prioritizeTrack: may have marked it after the caller decided, and
    // before this operation existed.
    if ([self priorityMarkForEntryLocked:entry]) {
        userInitiatedParse = YES;
        parse.qualityOfService = NSQualityOfServiceUserInitiated;
        parse.queuePriority = NSOperationQueuePriorityHigh;
    }
    for (id<AudioTrackMetadataHolder> track in entry.tracks) {
        [_parseOperationsByTrack setObject:parse forKey:track];
    }
#if DEBUG
    [self debugNoteScheduledParseQualityOfService:parse.qualityOfService];
#endif
    os_unfair_lock_unlock(&_materializationLock);
    [_queue addOperation:parse];
    return userInitiatedParse;
}

- (void)finishParseOperation:(NSOperation *)operation forEntry:(MetadataScanEntry *)entry {
    os_unfair_lock_lock(&_materializationLock);
    for (id<AudioTrackMetadataHolder> track in entry.tracks) {
        if ([_parseOperationsByTrack objectForKey:track] == operation) {
            [_parseOperationsByTrack removeObjectForKey:track];
        }
    }
    os_unfair_lock_unlock(&_materializationLock);
}

// Stage 2: the TagLib parse, entered only after materialization was Ready.
// Answers YES when the parse read another version than its key named. The
// record, with the claim's waiters, then parses again.
- (BOOL)parseOneEntry:(MetadataScanEntry *)entry {
    if (self.isCancelled) {
        return NO;
    }
    // A mark adopted since Ready leads too.
    os_unfair_lock_lock(&_materializationLock);
    [self leadEntryWithItsMarkedRowLocked:entry];
    os_unfair_lock_unlock(&_materializationLock);
    NSArray<id<AudioTrackMetadataHolder>> *tracks = entry.tracks;
    if ([self holdsCurrentMetadata:tracks.firstObject]) {
        [self settleTracks:tracks withMetadata:tracks.firstObject.metadata];
        return NO;
    }
    // A priority edge landing while the parse is queued has no record to
    // carry it, so entry and settlement both retire it.
    [self retirePriorityMarksSatisfiedByTracks:tracks];
    // Rows ahead of the owner joined another lane's holder, which serves them.
    MetadataParseClaim *claim = nil;
    NSUInteger ownerIndex = 0;
    for (; ownerIndex < tracks.count; ownerIndex++) {
        claim = [_parseCoordinator claimParseForKey:entry.standardizedPath
                                        participant:tracks[ownerIndex]];
        if (claim.isOwner) {
            break;
        }
    }
    if (!claim.isOwner) {
        [self finishTracks:tracks];
        return NO;
    }
    id<AudioTrackMetadataHolder> track = tracks[ownerIndex];
    // Another lane or a prior holder may have resolved it before the claim.
    AudioTrackMetadata *result = ([self holdsCurrentMetadata:track] || [self loadTrackFromDiskCache:track])
            ? track.metadata : [self parseAndCacheMetadataForTrack:track];
    if (!result) {
        NSArray<id<AudioTrackMetadataHolder>> *waiters = [_parseCoordinator completeClaim:claim];
        NSMutableArray<id<AudioTrackMetadataHolder>> *rows = [tracks mutableCopy];
        for (id<AudioTrackMetadataHolder> waiter in waiters) {
            if ([rows indexOfObjectIdenticalTo:waiter] == NSNotFound) {
                [rows addObject:waiter];
            }
        }
        os_unfair_lock_lock(&_materializationLock);
        entry.tracks = rows;
        os_unfair_lock_unlock(&_materializationLock);
        return YES;
    }
    if (result.parsedOK) {
        // NO for a resolved holder, already published.
        BOOL publishHolder = [track installMetadataIfUnresolved:result];
        NSMutableArray<id<AudioTrackMetadataHolder>> *adopted = [NSMutableArray array];
        BOOL completed = NO;
        do {
            NSArray<id<AudioTrackMetadataHolder>> *waiters =
                    [_parseCoordinator drainWaitersForSuccessfulClaim:claim
                                                              completed:&completed];
            [adopted addObjectsFromArray:
                    [self installCopiesOfMetadata:result onTracks:waiters]];
        } while (!completed);
        if (publishHolder) {
            [self publishTrack:track];
        }
        for (id<AudioTrackMetadataHolder> waiter in adopted) {
            [self publishTrack:waiter];
        }
        [self settleTracks:tracks withMetadata:result];
        return NO;
    }

    BOOL publishFallback = [track installMetadataIfUnresolved:result];
    NSArray<id<AudioTrackMetadataHolder>> *waiters = [_parseCoordinator completeClaim:claim];
    if (publishFallback) {
        [self publishTrack:track expectedMetadata:result];
    }
    for (id<AudioTrackMetadataHolder> waiter in waiters) {
        AudioTrackMetadata *copy = [result copy];
        if ([waiter installMetadataIfUnresolved:copy]) {
            [self publishTrack:waiter expectedMetadata:copy];
        }
    }
    [self finishTracks:[tracks subarrayWithRange:NSMakeRange(0, ownerIndex + 1)]];
    // Only the row it read for takes a failure: the rows past it try the file
    // for themselves, as a record of their own.
    NSRange rest = NSMakeRange(ownerIndex + 1, tracks.count - ownerIndex - 1);
    if (rest.length > 0 && !self.isCancelled) {
        [self enqueueScanMaterialization:[[MetadataScanEntry alloc]
                initWithTracks:[tracks subarrayWithRange:rest]
              standardizedPath:entry.standardizedPath
                 playlistIndex:entry.playlistIndex]];
        [self dispatchNextScanMaterialization];
    }
    return NO;
}

- (NSArray<id<AudioTrackMetadataHolder>> *)installCopiesOfMetadata:(AudioTrackMetadata *)metadata
                                                             onTracks:(NSArray<id<AudioTrackMetadataHolder>> *)tracks {
    NSMutableArray<id<AudioTrackMetadataHolder>> *installed = [NSMutableArray array];
    for (id<AudioTrackMetadataHolder> track in tracks) {
        AudioTrackMetadata *copy = [metadata copy];
        if ([track installMetadataIfUnresolved:copy]) {
            [installed addObject:track];
        }
    }
    return installed;
}

// Ends each track's scan and retires the marks they satisfy.
- (void)finishTracks:(NSArray<id<AudioTrackMetadataHolder>> *)tracks {
    os_unfair_lock_lock(&_materializationLock);
    for (id<AudioTrackMetadataHolder> track in tracks) {
        [_tracksWithScanInFlight removeObject:track];
    }
    BOOL retired = [self retirePriorityMarksTargetingTracksLocked:tracks];
    os_unfair_lock_unlock(&_materializationLock);
    if (retired) {
        [self dispatchNextScanMaterialization];
    }
}

// Copies into every track still unresolved and publishes it, then finishes
// them all.
- (void)settleTracks:(NSArray<id<AudioTrackMetadataHolder>> *)tracks withMetadata:(AudioTrackMetadata *)metadata {
    for (id<AudioTrackMetadataHolder> adopted in [self installCopiesOfMetadata:metadata onTracks:tracks]) {
        [self publishTrack:adopted];
    }
    [self finishTracks:tracks];
}

// nil when the parse read another version than its key names.
- (nullable AudioTrackMetadata *)parseAndCacheMetadataForTrack:(id<AudioTrackMetadataHolder>)track {
    AudioTrackMetadataCache *owner = _owner;
    // Before the parse, which can block for minutes: an invalidate during it
    // makes the result stale for the cache.
    uint64_t generation = owner.cacheGeneration;
    NSString *cacheKey = track.cacheKey;
    // A local, so every skipped write below releases it with the frame.
    NSData *displayArt = nil;
    NSData *pictureDigest = nil;
    AudioTrackMetadata *metadata = _fileParser
            ? _fileParser(track.url)
            : [AudioTrackMetadata metadataWithURL:track.url displayArtData:&displayArt pictureDigest:&pictureDigest];
    // TRAP: the version is checked here, at the parse's completion, never at
    // its start. The key was taken before the read. A placeholder's parse can
    // read from the download that installs another version, and that download
    // re-keys only when it ends. The re-key has retired the item's memo by
    // now, so its key names the version the file holds. A stale result is
    // neither installed, delivered nor filed, since its bytes may be either
    // version's. The record, with the claim's waiters, parses once more
    // under the new key. It is not requeued through the lane, because the new
    // version is already on disk and the lane would drop a priority record's
    // mark. The item's key is compared, never a fresh stat, so the next parse
    // is keyed as the check is.
    NSString *currentKey = track.cacheKey;
    if (currentKey != cacheKey && ![currentKey isEqualToString:cacheKey]) {
        LogInfo(@"Tags of %@ were read from another version than its key's; parsing again",
                track.url.lastPathComponent);
        return nil;
    }
    [metadata setCacheKey:cacheKey];
    if (metadata.parsedOK && cacheKey) {
        [self fileMetadata:metadata displayArt:displayArt pictureDigest:pictureDigest forKey:cacheKey
                generation:generation];
    }
    return metadata;
}

- (void)fileMetadata:(AudioTrackMetadata *)metadata
          displayArt:(nullable NSData *)displayArt
       pictureDigest:(nullable NSData *)pictureDigest
              forKey:(NSString *)cacheKey
          generation:(uint64_t)generation {
    // A failed parse is never cached: its fallback would shadow the real
    // tags until the cache key changed. The write is synchronous so its
    // back-pressure paces the workers. The generation is rechecked after the
    // write because an invalidation can slip between check and write, and
    // the remove keeps Clear Cache empty. Use the strong `owner`, never
    // _owner, so the pair cannot see the cache vanish midway.
    AudioTrackMetadataCache *owner = _owner;
    if (!owner || generation != owner.cacheGeneration) {
        return;
    }
    VibeMetadataStore *store = owner.metadataCache;
    // The parse encoded the thumbnail before publication. nil when that
    // failed, and the rendition stands in. A part the picture has already,
    // from another file that embeds it, is not written again.
    NSString *picture = [store fileTags:metadata
                              thumbnail:metadata.artwork.encodedThumbnailDataForStorage
                              rendition:displayArt
                            pictureName:pictureDigest ? [VibeMetadataStore nameOfPictureWithDigest:pictureDigest] : nil
                                 forKey:cacheKey];
    if (generation != owner.cacheGeneration) {
        [store removeEntryForKey:cacheKey];
    }
    VibeInstallArchivedArtProviders(metadata, store, picture);
}

// Not gated on isCancelled: every caller won an install. The identity guard
// decides delivery, and the delegate drops a departed track.
- (void)publishTrack:(id<AudioTrackMetadataHolder>)track {
    [self publishTrack:track expectedMetadata:track.metadata];
}

- (void)publishTrack:(id<AudioTrackMetadataHolder>)track
    expectedMetadata:(AudioTrackMetadata *)expectedMetadata {
    if (!expectedMetadata) {
        return;
    }
    run_on_main_thread({
        // Holds the track monitor through the delegate, which may read
        // track.metadata but must never wait on a metadata worker.
        [track deliverIfMetadataStillInstalled:expectedMetadata usingBlock:^{
            [self.delegate didLoadMetadata:track];
        }];
    });
}

@end
