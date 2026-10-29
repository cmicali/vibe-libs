//
//  AudioTrackMetadataLoader+Reading.m
//  vibe-libs
//
//  A client's reads by URL: the disk cache, then a parse under the read's
//  policy, then the cache write. No holder, record, mark, or materialization.
//

#import "AudioTrackMetadataLoaderInternal.h"
#import "AudioTrackMetadataCacheInternal.h"
#import "AudioTrackMetadata.h"
#import "AudioTrackMetadataInternal.h"
#import "NSURL+Hash.h"
#import "PlaceholderFiles.h"
#import "VibeMacros.h"

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/resource.h>
#include <unistd.h>

// Runs block with this thread unable to materialize a dataless file: a read
// of one fails with EDEADLK, and the file stays in the cloud. Measured on
// macOS 27.2 against iCloud Drive and Dropbox placeholders: the open
// succeeds, and every read fails.
// TRAP: thread scope, restored after. The thread is the queue's, and runs
// other work next, such as a sweep's parse that may materialize.
static void VibeWithoutMaterializing(NS_NOESCAPE dispatch_block_t block) {
    int previous = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD);
    BOOL set = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD,
                              IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0;
    if (!set) {
        LogWarn(@"Could not turn materialization off for a tag read: %s", strerror(errno));
    }
    block();
    if (set && previous >= 0) {
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previous);
    }
}

@implementation AudioTrackMetadataLoader (Reading)

- (void)readURLs:(NSArray<NSURL *> *)urls
          policy:(VibeMetadataReadPolicy)policy
        progress:(NSProgress *)progress
   deliveryQueue:(dispatch_queue_t)deliveryQueue
          result:(void (^)(VibeMetadataReadResult *result))result
      completion:(dispatch_block_t)completion {
    // Each answer is dispatched into the group before its worker leaves it,
    // so the notify runs after the last answer.
    dispatch_group_t group = dispatch_group_create();
    NSUInteger workerCount = MIN((NSUInteger)_queue.maxConcurrentOperationCount, urls.count);
    // Shared by this call's workers alone, under the lock.
    __block NSUInteger cursor = 0;
    NSLock *lock = [[NSLock alloc] init];
    // Workers hold the loader weakly: the cache keeps it, and a departed
    // cache answers every file not begun as Cancelled.
    __weak __typeof(self) weakSelf = self;
    for (NSUInteger worker = 0; worker < workerCount; worker++) {
        dispatch_group_enter(group);
        [_queue addOperationWithBlock:^{
            for (;;) {
                NSURL *url = nil;
                [lock lock];
                if (cursor < urls.count) {
                    url = urls[cursor++];
                }
                [lock unlock];
                if (!url) {
                    break;
                }
                VibeMetadataReadResult *answer = nil;
                {
                    __typeof(self) strongSelf = weakSelf;
                    answer = (strongSelf && !progress.cancelled)
                            ? [strongSelf readURL:url policy:policy]
                            : [[VibeMetadataReadResult alloc] initWithURL:url
                                                                  outcome:VibeMetadataReadOutcomeCancelled
                                                                 cacheKey:nil metadata:nil fromCache:NO error:nil];
                }
                [lock lock];
                progress.completedUnitCount += 1;
                [lock unlock];
                dispatch_group_async(group, deliveryQueue, ^{
                    result(answer);
                });
            }
            dispatch_group_leave(group);
        }];
    }
    dispatch_group_notify(group, deliveryQueue, completion);
}

- (VibeMetadataReadResult *)readURL:(NSURL *)url policy:(VibeMetadataReadPolicy)policy {
    // One stat, and no content read.
    NSString *cacheKey = url.cacheKey;
    if (!cacheKey) {
        return [self answerFor:url outcome:VibeMetadataReadOutcomeMissing cacheKey:nil metadata:nil error:nil];
    }
    AudioTrackMetadata *cached = [self cachedMetadataForKey:cacheKey];
    if (cached) {
        return [[VibeMetadataReadResult alloc] initWithURL:url outcome:VibeMetadataReadOutcomeRead
                                                  cacheKey:cacheKey metadata:cached fromCache:YES error:nil];
    }
    // A remote placeholder answers dataless too.
    if (policy == VibeMetadataReadPolicyCacheOnly || [PlaceholderFiles isDatalessFile:url]) {
        return [self answerFor:url outcome:VibeMetadataReadOutcomeCacheMiss cacheKey:cacheKey metadata:nil error:nil];
    }
    // The open alone tells an unreadable file from one that is not audio.
    // O_NONBLOCK, so a FIFO under an audio name cannot wedge the worker.
    int fd = open(url.fileSystemRepresentation, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) {
        NSError *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{NSURLErrorKey: url}];
        return [self answerFor:url outcome:VibeMetadataReadOutcomeUnreadable cacheKey:cacheKey metadata:nil
                         error:error];
    }
    close(fd);
    // Before the parse: an invalidate during it makes the result stale for
    // the cache.
    uint64_t generation = _owner.cacheGeneration;
    __block NSData *displayArt = nil;
    __block AudioTrackMetadata *metadata = nil;
    VibeWithoutMaterializing(^{
        NSData *art = nil;
        metadata = self->_fileParser ? self->_fileParser(url)
                                     : [AudioTrackMetadata metadataWithURL:url displayArtData:&art];
        displayArt = art;
    });
    // TRAP: checked at the parse's completion, as the sweep's is. Its bytes
    // may be either version's, so it is neither filed nor answered as Read.
    NSString *currentKey = url.cacheKey;
    if (currentKey != cacheKey && ![currentKey isEqualToString:cacheKey]) {
        return [self answerFor:url outcome:VibeMetadataReadOutcomeChanged cacheKey:cacheKey metadata:nil error:nil];
    }
    [metadata setCacheKey:cacheKey];
    if (!metadata.parsedOK) {
        // Evicted after the check: the policy failed the read.
        if ([PlaceholderFiles isDatalessFile:url]) {
            return [self answerFor:url outcome:VibeMetadataReadOutcomeCacheMiss cacheKey:cacheKey metadata:nil
                             error:nil];
        }
        return [self answerFor:url outcome:VibeMetadataReadOutcomeNotParsed cacheKey:cacheKey metadata:metadata
                         error:nil];
    }
    [self fileMetadata:metadata displayArt:displayArt forKey:cacheKey generation:generation];
    return [[VibeMetadataReadResult alloc] initWithURL:url outcome:VibeMetadataReadOutcomeRead cacheKey:cacheKey
                                              metadata:metadata fromCache:NO error:nil];
}

- (VibeMetadataReadResult *)answerFor:(NSURL *)url
                              outcome:(VibeMetadataReadOutcome)outcome
                             cacheKey:(NSString *)cacheKey
                             metadata:(AudioTrackMetadata *)metadata
                                error:(NSError *)error {
    return [[VibeMetadataReadResult alloc] initWithURL:url outcome:outcome cacheKey:cacheKey metadata:metadata
                                             fromCache:NO error:error];
}

@end
