//
//  VibeLocationStore.m
//  vibe-libs
//

#import "VibeLocationStore.h"
#import "FilePaths.h"

#import "BrowserRules.h"
#import "VibeLocationStoreInternal.h"
#import "VibeMacros.h"

NSNotificationName const VibeLocationsDidChangeNotification =
        @"VibeLocationsDidChangeNotification";

// The app's, set at launch (configureWithBookmarksKey:…).
static NSString *sBookmarksKey;
static NSString *sSuppressionsKey;
static NSString *const kSuppressedBookmarkKey = @"bookmark";
static NSString *const kSuppressedRootPathsKey = @"rootPaths";
static const NSInteger kMaximumConcurrentBookmarkRestorations = 3;

// Main only. The app sets it before any scene connects.
static NSString *_Nullable (^sRootNamer)(NSURL *, NSString *);

@interface VibeLocationEntry : NSObject
@property (nonatomic) NSURL *url;
// Resolved off main with the bookmark, since asking the file system for a
// provider folder's name can block; nil until then.
@property (nonatomic, nullable) NSString *displayName;
@property (nonatomic, nullable) NSData *bookmark;
@property (nonatomic) BOOL scopeStarted;
@property (nonatomic) NSUInteger ordinal;
// A parent whose bookmark is not durable yet owns the narrower entries it
// replaced, so their bookmarks remain the relaunch state until minting settles.
@property (nonatomic) NSArray<VibeLocationEntry *> *replacedEntries;
@property (nonatomic) NSUInteger sessionGrantCount;
@property (nonatomic) BOOL retired;
@end

@implementation VibeLocationEntry
- (instancetype)init {
    self = [super init];
    if (self) {
        _replacedEntries = @[];
    }
    return self;
}
@end

// One persisted bookmark restoration and the root removals that are allowed to
// suppress only this identity after its provider finally resolves the URL.
@interface VibePendingLocationRestore : NSObject
@property (nonatomic) NSData *bookmark;
@property (nonatomic) NSMutableOrderedSet<NSString *> *suppressedRootPaths;
@end

@implementation VibePendingLocationRestore
@end

@class VibeLocationStore;

@interface VibeLocationGrant () {
    VibeLocationStore *_store;
    VibeLocationEntry *_entry;
}
- (instancetype)initWithStore:(VibeLocationStore *)store entry:(VibeLocationEntry *)entry;
@end

@interface VibeLocationStore ()
- (void)releaseSessionGrantForEntry:(VibeLocationEntry *)entry;
@end

@implementation VibeLocationGrant

- (instancetype)initWithStore:(VibeLocationStore *)store entry:(VibeLocationEntry *)entry {
    self = [super init];
    if (self) {
        _store = store;
        _entry = entry;
        _rootURL = entry.url;
    }
    return self;
}

- (void)dealloc {
    VibeLocationStore *store = _store;
    VibeLocationEntry *entry = _entry;
    if (NSThread.isMainThread) {
        [store releaseSessionGrantForEntry:entry];
    }
    else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [store releaseSessionGrantForEntry:entry];
        });
    }
}

@end

@implementation VibeLocationStore {
    // Main-confined. An entry remains alive after removal while a FolderSession
    // grant still retains it; retirement balances the scope when the last one
    // releases.
    NSMutableArray<VibeLocationEntry *> *_folders;
    NSMutableDictionary<NSNumber *, VibePendingLocationRestore *> *_pendingRestorations;
    NSUInteger _nextEntryOrdinal;
    BOOL _restoreStarted;

    // Minting has its own queue, so a provider stalled in the launch restore
    // cannot park a folder the user adds.
    NSOperationQueue *_restoreQueue;
    dispatch_queue_t _bookmarkQueue;
}

+ (VibeLocationStore *)shared {
    static VibeLocationStore *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[VibeLocationStore alloc] initPrivate];
    });
    return shared;
}

- (instancetype)initPrivate {
    NSAssert(sBookmarksKey && sSuppressionsKey,
             @"VibeLocationStore: the app sets its keys before the store is used");
    self = [super init];
    if (self) {
        _folders = [NSMutableArray array];
        _pendingRestorations = [NSMutableDictionary dictionary];

        _restoreQueue = [[NSOperationQueue alloc] init];
        _restoreQueue.name = @"VibeLocationStore.restore";
        _restoreQueue.qualityOfService = NSQualityOfServiceUtility;
        _restoreQueue.maxConcurrentOperationCount = kMaximumConcurrentBookmarkRestorations;

        dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(
                DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
        _bookmarkQueue = dispatch_queue_create("VibeLocationStore.bookmark", attributes);
    }
    return self;
}

- (void)dealloc {
    [_restoreQueue cancelAllOperations];
    for (VibeLocationEntry *folder in _folders) {
        [self retireScopeTree:folder];
    }
}

#pragma mark - Reading

+ (void)configureWithBookmarksKey:(NSString *)bookmarksKey
                  suppressionsKey:(NSString *)suppressionsKey
                        rootNamer:(NSString *_Nullable (^)(NSURL *, NSString *))rootNamer {
    sBookmarksKey = [bookmarksKey copy];
    sSuppressionsKey = [suppressionsKey copy];
    sRootNamer = [rootNamer copy];
}

- (NSArray<NSURL *> *)folderURLs {
    NSMutableArray<NSURL *> *urls = [NSMutableArray arrayWithCapacity:_folders.count];
    for (VibeLocationEntry *folder in _folders) {
        [urls addObject:folder.url];
    }
    return urls;
}

// The app's own Documents directory: readable with no grant, so it is always a
// root and can never be a row.
+ (NSURL *)containerDocumentsURL {
    return [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory
                                                inDomains:NSUserDomainMask].firstObject;
}

- (NSArray<NSURL *> *)searchRoots {
    NSMutableArray<NSURL *> *roots = [[self folderURLs] mutableCopy];
    NSURL *documents = [VibeLocationStore containerDocumentsURL];
    if (documents) {
        [roots addObject:documents];
    }
    return roots;
}

// Spelling and stored names only, never the disk: asking a provider's folder
// for its name is IPC that can block main.
+ (NSString *)displayNameForFolderURL:(NSURL *)url {
    NSString *path = VibeComparablePath(url.path);
    NSString *rootName = sRootNamer ? sRootNamer(url, path ?: @"") : nil;
    if (rootName) {
        return rootName;
    }
    for (VibeLocationEntry *folder in VibeLocationStore.shared->_folders) {
        if ([VibeComparablePath(folder.url.path) isEqualToString:path]) {
            return folder.displayName ?: url.lastPathComponent;
        }
    }
    return url.lastPathComponent;
}

#pragma mark - Restoring

- (void)restorePersistedFolders {
    if (_restoreStarted) {
        return;
    }
    _restoreStarted = YES;

    NSArray *stored = [NSUserDefaults.standardUserDefaults
            arrayForKey:sBookmarksKey];
    NSArray *suppressionRecords = [NSUserDefaults.standardUserDefaults
            arrayForKey:sSuppressionsKey];
    for (id value in stored) {
        if (![value isKindOfClass:NSData.class]) {
            continue;
        }
        NSData *bookmark = value;
        NSUInteger ordinal = _nextEntryOrdinal++;
        NSNumber *key = @(ordinal);
        VibePendingLocationRestore *pending = [[VibePendingLocationRestore alloc] init];
        pending.bookmark = bookmark;
        pending.suppressedRootPaths = [NSMutableOrderedSet orderedSetWithArray:
                [self suppressedRootPathsForBookmark:bookmark inRecords:suppressionRecords]];
        _pendingRestorations[key] = pending;
        [_restoreQueue addOperationWithBlock:^{
            VibeLocationEntry *folder = [self resolveBookmark:bookmark];
            dispatch_async(dispatch_get_main_queue(), ^{
                VibePendingLocationRestore *livePending = self->_pendingRestorations[key];
                if (!livePending) {
                    [self retireScopeTree:folder];
                    return;
                }
                [self->_pendingRestorations removeObjectForKey:key];
                BOOL rowsChanged = NO;
                if (folder) {
                    folder.ordinal = ordinal;
                    NSString *path = VibeComparablePath(folder.url.path);
                    if (VibeLocationRestoreIsSuppressed(
                            livePending.suppressedRootPaths.array,
                            [self persistentRootPaths], path)) {
                        [self retireScopeTree:folder];
                    }
                    else {
                        rowsChanged = [self mergeEntry:folder];
                    }
                }
                [self persistBookmarks];
                if (rowsChanged) {
                    [self notifyFoldersChanged];
                }
            });
        }];
    }
    if (_pendingRestorations.count == 0) {
        [NSUserDefaults.standardUserDefaults
                removeObjectForKey:sSuppressionsKey];
    }
}

- (NSArray<NSString *> *)suppressedRootPathsForBookmark:(NSData *)bookmark
                                               inRecords:(NSArray *)records {
    NSMutableOrderedSet<NSString *> *paths = [NSMutableOrderedSet orderedSet];
    for (id value in records) {
        if (![value isKindOfClass:NSDictionary.class]
                || ![value[kSuppressedBookmarkKey] isEqual:bookmark]) {
            continue;
        }
        id storedPaths = value[kSuppressedRootPathsKey];
        if (![storedPaths isKindOfClass:NSArray.class]) {
            continue;
        }
        for (id path in storedPaths) {
            // Re-spelled: a stored path may carry the /private that the file
            // system's standardizing keeps.
            if ([path isKindOfClass:NSString.class] && [path length] > 0) {
                [paths addObject:VibeComparablePath(path)];
            }
        }
    }
    return paths.array;
}

// Restore queue only. A stale bookmark is re-minted after the scope starts,
// since minting needs it open.
- (VibeLocationEntry *)resolveBookmark:(NSData *)bookmark {
    BOOL stale = NO;
    NSError *error = nil;
    NSURL *url = [NSURL URLByResolvingBookmarkData:bookmark
                                           options:0
                                     relativeToURL:nil
                               bookmarkDataIsStale:&stale
                                             error:&error];
    if (!url) {
        LogWarn(@"VibeLocationStore: dropping a folder whose bookmark no longer resolves (%@)",
                error);
        return nil;
    }
    VibeLocationEntry *folder = [[VibeLocationEntry alloc] init];
    folder.url = url;
    // NO is not failure: the app's own container is not security-scoped.
    folder.scopeStarted = [url startAccessingSecurityScopedResource];
    folder.displayName = [NSFileManager.defaultManager displayNameAtPath:url.path];
    folder.bookmark = stale ? ([self bookmarkForURL:url] ?: bookmark) : bookmark;
    return folder;
}

// iOS has no WithSecurityScope option: a default bookmark of a granted URL
// carries the scope, provided the scope is open.
- (NSData *)bookmarkForURL:(NSURL *)url {
    NSError *error = nil;
    NSData *bookmark = [url bookmarkDataWithOptions:0
                     includingResourceValuesForKeys:nil
                                      relativeToURL:nil
                                              error:&error];
    if (!bookmark) {
        LogWarn(@"VibeLocationStore: could not bookmark %@ (%@)", url, error);
    }
    return bookmark;
}

#pragma mark - Adding and removing

- (BOOL)addFolderURL:(NSURL *)url {
    if ([self isCoveredByAPersistentRoot:url]) {
        return NO;
    }

    VibeLocationEntry *folder = [[VibeLocationEntry alloc] init];
    folder.url = url;
    folder.scopeStarted = [url startAccessingSecurityScopedResource];
    folder.ordinal = _nextEntryOrdinal++;
    [self mergeEntry:folder];
    [self persistAndNotify];

    // Until the mint lands, the replaced entries remain the relaunch state.
    dispatch_async(_bookmarkQueue, ^{
        NSString *name = [NSFileManager.defaultManager displayNameAtPath:url.path];
        NSData *bookmark = [self bookmarkForURL:url];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![self entryIsLive:folder]) {
                return;
            }
            if (name) {
                folder.displayName = name;
                [self notifyFoldersChanged];
            }
            if (!bookmark) {
                return;
            }
            folder.bookmark = bookmark;
            [self suppressPendingRestorationsCoveredByURL:folder.url];
            for (VibeLocationEntry *replacedEntry in folder.replacedEntries) {
                [self retireScopeTree:replacedEntry];
            }
            folder.replacedEntries = @[];
            [self persistBookmarks];
        });
    });
    return YES;
}

- (void)removeFolderAtIndex:(NSUInteger)index {
    if (index >= _folders.count) {
        return;
    }
    VibeLocationEntry *folder = _folders[index];
    [self suppressPendingRestorationsCoveredByURL:folder.url];
    [_folders removeObjectAtIndex:index];
    [self retireScopeTree:folder];
    [self persistAndNotify];
}

// The one merge for additions and restores alike (FileSearchRules.h), inserting
// by original order.
- (BOOL)mergeEntry:(VibeLocationEntry *)candidate {
    NSString *candidatePath = VibeComparablePath(candidate.url.path);
    NSURL *documents = [VibeLocationStore containerDocumentsURL];
    if (documents && VibeLocationRootCoversPath(
            VibeComparablePath(documents.path), candidatePath)) {
        [self retireScopeTree:candidate];
        return NO;
    }
    NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithCapacity:_folders.count];
    for (VibeLocationEntry *folder in _folders) {
        [paths addObject:VibeComparablePath(folder.url.path) ?: @""];
    }

    NSUInteger coveringIndex = VibeLocationCoveringRootIndex(paths, candidatePath);
    if (coveringIndex != NSNotFound) {
        VibeLocationEntry *covering = _folders[coveringIndex];
        if (!covering.bookmark) {
            covering.replacedEntries = [covering.replacedEntries
                    arrayByAddingObject:candidate];
        }
        else {
            [self suppressPendingRestorationsCoveredByURL:covering.url];
            [self retireScopeTree:candidate];
        }
        return NO;
    }

    NSIndexSet *covered = VibeLocationIndexesCoveredByRoot(paths, candidatePath);
    NSArray<VibeLocationEntry *> *replaced = [_folders objectsAtIndexes:covered];
    [_folders removeObjectsAtIndexes:covered];
    if (!candidate.bookmark) {
        candidate.replacedEntries = [candidate.replacedEntries
                arrayByAddingObjectsFromArray:replaced];
    }
    else {
        for (VibeLocationEntry *folder in replaced) {
            [self retireScopeTree:folder];
        }
    }
    if (candidate.bookmark) {
        [self suppressPendingRestorationsCoveredByURL:candidate.url];
    }

    NSUInteger insertionIndex = [_folders indexOfObjectPassingTest:^BOOL(
            VibeLocationEntry *folder, NSUInteger index, BOOL *stop) {
        return folder.ordinal > candidate.ordinal;
    }];
    if (insertionIndex == NSNotFound) {
        insertionIndex = _folders.count;
    }
    [_folders insertObject:candidate atIndex:insertionIndex];
    return YES;
}

- (void)suppressPendingRestorationsCoveredByURL:(NSURL *)url {
    NSString *rootPath = VibeComparablePath(url.path);
    if (rootPath.length == 0) {
        return;
    }
    for (VibePendingLocationRestore *pending in _pendingRestorations.allValues) {
        [pending.suppressedRootPaths addObject:rootPath];
    }
}

- (BOOL)entryIsLive:(VibeLocationEntry *)candidate {
    for (VibeLocationEntry *folder in _folders) {
        if ([self entry:candidate isInTree:folder]) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)entry:(VibeLocationEntry *)candidate isInTree:(VibeLocationEntry *)folder {
    if (candidate == folder) {
        return YES;
    }
    for (VibeLocationEntry *replaced in folder.replacedEntries) {
        if ([self entry:candidate isInTree:replaced]) {
            return YES;
        }
    }
    return NO;
}

// Never the transient FolderSession roots, which are gone at the next open.
- (BOOL)isCoveredByAPersistentRoot:(NSURL *)url {
    return VibeLocationCoveringRootIndex(
            [self persistentRootPaths], VibeComparablePath(url.path)) != NSNotFound;
}

- (NSArray<NSString *> *)persistentRootPaths {
    NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithCapacity:_folders.count + 1];
    NSURL *documents = [VibeLocationStore containerDocumentsURL];
    NSString *documentsPath = VibeComparablePath(documents.path);
    if (documentsPath.length > 0) {
        [paths addObject:documentsPath];
    }
    for (VibeLocationEntry *folder in _folders) {
        NSString *path = VibeComparablePath(folder.url.path);
        if (path.length > 0) {
            [paths addObject:path];
        }
    }
    return paths;
}

#pragma mark - Session grants

- (VibeLocationGrant *)grantCoveringURL:(NSURL *)url {
    NSString *path = VibeComparablePath(url.path);
    VibeLocationEntry *best = nil;
    NSUInteger bestLength = 0;
    for (VibeLocationEntry *folder in _folders) {
        NSString *rootPath = VibeComparablePath(folder.url.path);
        if (VibeLocationRootCoversPath(rootPath, path) && (!best || rootPath.length > bestLength)) {
            best = folder;
            bestLength = rootPath.length;
        }
    }
    if (!best) {
        return nil;
    }
    best.sessionGrantCount++;
    return [[VibeLocationGrant alloc] initWithStore:self entry:best];
}

- (void)releaseSessionGrantForEntry:(VibeLocationEntry *)entry {
    if (entry.sessionGrantCount == 0) {
        return;
    }
    entry.sessionGrantCount--;
    [self finishRetiringEntryIfPossible:entry];
}

- (void)retireScopeTree:(VibeLocationEntry *)folder {
    if (folder.retired) {
        return;
    }
    folder.retired = YES;
    [self finishRetiringEntryIfPossible:folder];
    for (VibeLocationEntry *replaced in folder.replacedEntries) {
        [self retireScopeTree:replaced];
    }
}

- (void)finishRetiringEntryIfPossible:(VibeLocationEntry *)folder {
    if (!folder.retired || folder.sessionGrantCount != 0 || !folder.scopeStarted) {
        return;
    }
    [folder.url stopAccessingSecurityScopedResource];
    folder.scopeStarted = NO;
}

#pragma mark - Persistence

- (void)persistAndNotify {
    [self persistBookmarks];
    [self notifyFoldersChanged];
}

- (void)notifyFoldersChanged {
    [NSNotificationCenter.defaultCenter
            postNotificationName:VibeLocationsDidChangeNotification object:self];
}

- (void)persistBookmarks {
    // Completions land out of order, so live and pending bookmarks are merged
    // by original ordinal.
    NSMutableDictionary<NSNumber *, NSData *> *bookmarksByOrdinal =
            [NSMutableDictionary dictionary];
    for (VibeLocationEntry *folder in _folders) {
        [self appendDurableBookmarksForFolder:folder toDictionary:bookmarksByOrdinal];
    }
    NSArray<NSNumber *> *pendingOrdinals = [_pendingRestorations.allKeys
            sortedArrayUsingSelector:@selector(compare:)];
    for (NSNumber *ordinal in pendingOrdinals) {
        if (!bookmarksByOrdinal[ordinal]) {
            bookmarksByOrdinal[ordinal] = _pendingRestorations[ordinal].bookmark;
        }
    }

    NSMutableArray<NSData *> *bookmarks = [NSMutableArray array];
    NSMutableSet<NSData *> *seen = [NSMutableSet set];
    NSArray<NSNumber *> *durableOrdinals = [bookmarksByOrdinal.allKeys
            sortedArrayUsingSelector:@selector(compare:)];
    for (NSNumber *ordinal in durableOrdinals) {
        NSData *bookmark = bookmarksByOrdinal[ordinal];
        if (![seen containsObject:bookmark]) {
            [seen addObject:bookmark];
            [bookmarks addObject:bookmark];
        }
    }
    if (bookmarks.count > 0) {
        [NSUserDefaults.standardUserDefaults setObject:bookmarks forKey:sBookmarksKey];
    }
    else {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:sBookmarksKey];
    }

    NSMutableArray<NSDictionary *> *suppressionRecords = [NSMutableArray array];
    for (NSNumber *ordinal in pendingOrdinals) {
        VibePendingLocationRestore *pending = _pendingRestorations[ordinal];
        if (pending.suppressedRootPaths.count > 0) {
            [suppressionRecords addObject:@{
                kSuppressedBookmarkKey: pending.bookmark,
                kSuppressedRootPathsKey: pending.suppressedRootPaths.array
            }];
        }
    }
    if (suppressionRecords.count > 0) {
        [NSUserDefaults.standardUserDefaults setObject:suppressionRecords
                                                  forKey:sSuppressionsKey];
    }
    else {
        [NSUserDefaults.standardUserDefaults
                removeObjectForKey:sSuppressionsKey];
    }
}

// A parent without its bookmark yet persists the entries it replaced.
- (void)appendDurableBookmarksForFolder:(VibeLocationEntry *)folder
                           toDictionary:(NSMutableDictionary<NSNumber *, NSData *> *)bookmarksByOrdinal {
    if (folder.bookmark) {
        bookmarksByOrdinal[@(folder.ordinal)] = folder.bookmark;
        return;
    }
    for (VibeLocationEntry *replaced in folder.replacedEntries) {
        [self appendDurableBookmarksForFolder:replaced toDictionary:bookmarksByOrdinal];
    }
}

@end
