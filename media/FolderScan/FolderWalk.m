//
//  FolderWalk.m
//  vibe-libs
//

#import "FolderWalkInternal.h"
#import "NSURL+Emptiness.h"
#import "PlaceholderFiles.h"
#import "PlayableExtensions.h"
#import "VibePlaylistEntry.h"
#import "VibePlaylistFile.h"
#import "VibeMacros.h"
#import "VibeMaterializing.h"

#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

// Takes an expansion's entries, in order, as they are made. NO stops it.
typedef BOOL (^VibeEntriesSink)(NSArray<VibePlaylistEntry *> *entries);

// Installed at launch, read from the expansion workers: every access locks.
static VibePlaylistFolderGrantHandler sPlaylistFolderGrantHandler;
static VibeWalkedFileHandler sWalkedFileHandler;
static VibeWalkedDirectoriesHandler sWalkedDirectoriesHandler;
static VibeBulkOpenDirectoriesHandler sBulkOpenDirectoriesHandler;
static VibeEmbeddedSheetReadHandler sEmbeddedSheetReadHandler;

// Whether the thread runs a catalog scan's walk, for the embedded-sheet
// handler. Each scan walks its roots on one thread of its own.
static __thread BOOL sScanning;

static VibeWalkedFileHandler WalkedFileHandler(void) {
    @synchronized (FolderWalk.class) {
        return sWalkedFileHandler;
    }
}

static VibeWalkedDirectoriesHandler WalkedDirectoriesHandler(void) {
    @synchronized (FolderWalk.class) {
        return sWalkedDirectoriesHandler;
    }
}

static VibeBulkOpenDirectoriesHandler BulkOpenDirectoriesHandler(void) {
    @synchronized (FolderWalk.class) {
        return sBulkOpenDirectoriesHandler;
    }
}

static VibeEmbeddedSheetReadHandler EmbeddedSheetReadHandler(void) {
    @synchronized (FolderWalk.class) {
        return sEmbeddedSheetReadHandler;
    }
}


// A walk's sheets, read: each sheet's entries, each claimed file, and the
// sheets not read.
@interface VibeWalkSheets : NSObject
@property (nonatomic) NSMutableDictionary<NSURL *, NSArray<VibePlaylistEntry *> *> *entriesBySheet;
// Each claimed file to the sheet that cut it.
@property (nonatomic) NSMutableDictionary<NSURL *, NSURL *> *claimed;
@property (nonatomic) NSMutableSet<NSURL *> *unreadSheets;
// The first unread sheet by path, which every entry names.
@property (nonatomic, nullable) NSURL *unread;
@end

@implementation VibeWalkSheets
@end


@implementation FolderWalk

+ (void)setPlaylistFolderGrantHandler:(VibePlaylistFolderGrantHandler)handler {
    @synchronized (self) {
        sPlaylistFolderGrantHandler = [handler copy];
    }
}

+ (void)setWalkedFileHandler:(VibeWalkedFileHandler)handler {
    @synchronized (self) {
        sWalkedFileHandler = [handler copy];
    }
}

+ (void)setWalkedDirectoriesHandler:(VibeWalkedDirectoriesHandler)handler {
    @synchronized (self) {
        sWalkedDirectoriesHandler = [handler copy];
    }
}

+ (void)setBulkOpenDirectoriesHandler:(VibeBulkOpenDirectoriesHandler)handler {
    @synchronized (self) {
        sBulkOpenDirectoriesHandler = [handler copy];
    }
}

+ (void)setEmbeddedSheetReadHandler:(VibeEmbeddedSheetReadHandler)handler {
    @synchronized (self) {
        sEmbeddedSheetReadHandler = [handler copy];
    }
}

// The directory a path resolves to, canonically spelled, or nil for a file or
// a broken link, with the reason in *error when given.
//
// TRAP: NSURLIsDirectoryKey is lstat-shaped: a link to a folder answers NO, and
// the enumerator refuses one as its root (ENOTDIR), so an unresolved folder
// link is taken for a file and dropped by the extension filter — a dragged
// ~/Music/NAS link opens to nothing. realpath, not URLByResolvingSymlinksInPath,
// which keeps a /private prefix: only realpath's spelling matches the
// enumerator's resolved paths.
static NSString *VibeResolvedDirectoryPath(NSString *path, int *error) {
    char resolved[PATH_MAX];
    struct stat st;
    int reason = 0;
    if (path.length == 0) {
        reason = ENOENT;
    }
    else if (!realpath(path.fileSystemRepresentation, resolved) || stat(resolved, &st) != 0) {
        reason = errno;
    }
    else if (!S_ISDIR(st.st_mode)) {
        reason = ENOTDIR;
    }
    if (reason != 0) {
        if (error) {
            *error = reason;
        }
        return nil;
    }
    return [NSFileManager.defaultManager stringWithFileSystemRepresentation:resolved
                                                                     length:strlen(resolved)];
}

// A string test, so the walk need not rebuild the parent path per entry.
static BOOL VibePathIsDirectlyInside(NSString *path, NSString *directory) {
    NSUInteger directoryLength = directory.length;
    if (directoryLength == 0 || path.length <= directoryLength + 1) {
        return NO;
    }
    if (![path hasPrefix:directory] || [path characterAtIndex:directoryLength] != '/') {
        return NO;
    }
    NSRange remainder = NSMakeRange(directoryLength + 1, path.length - directoryLength - 1);
    return [path rangeOfString:@"/" options:0 range:remainder].location == NSNotFound;
}

+ (NSSet<NSString*>*) supportedExtensions {
    return PlayableExtensions.lookup;
}

// byFullPath sorts a recursive walk by whole path, grouping subfolders. The
// name is also newest-first's tiebreak, so a batch copy reads in track order.
//
// Whole paths compare as one string, so a recursive walk's subfolders are not
// always grouped: case and accents weigh less than the next path component,
// so "e/a", "é/a", "E/m", and "e/z" sort in that order.
//
// TRAP: decorate the dates and names once, never read them in the comparator,
// which runs O(n log n) times: NSURL.path mints a string per read, and a date
// the enumeration did not prefetch is a file-provider round trip. They are
// read by position, as hashing an NSURL in the comparator costs a pass over
// its string; the positions sort as the URLs did, by the same comparisons.
//
// The order is a comparator over the urls' positions, so a caller can also
// pick the least of them in one pass. nil for as received, which keeps the
// listing's order.
typedef NSComparisonResult (^VibeURLOrder)(NSUInteger a, NSUInteger b);

static VibeURLOrder _Nullable VibeAudioURLOrder(NSArray<NSURL*> *urls, VibeFolderOpenSort sort, BOOL byFullPath) {
    if (sort == VibeFolderOpenSortAsReceived) {
        return nil;
    }
    NSUInteger count = urls.count;
    NSMutableArray<NSString*> *names = [NSMutableArray arrayWithCapacity:count];
    for (NSURL *url in urls) {
        [names addObject:(byFullPath ? url.path : url.lastPathComponent) ?: @""];
    }
    VibeURLOrder byName = ^(NSUInteger a, NSUInteger b) {
        return [names[a] localizedStandardCompare:names[b]];
    };
    if (sort != VibeFolderOpenSortNewestFirst) {
        return byName;
    }
    // NSNull for undated.
    NSMutableArray *dates = [NSMutableArray arrayWithCapacity:count];
    for (NSURL *url in urls) {
        NSDate *modified = nil;
        [url getResourceValue:&modified forKey:NSURLContentModificationDateKey error:NULL];
        [dates addObject:modified ?: NSNull.null];
    }
    // Undated files sort last, by name, keeping the order total.
    return ^NSComparisonResult(NSUInteger indexA, NSUInteger indexB) {
        id dateA = dates[indexA];
        id dateB = dates[indexB];
        if (dateA == NSNull.null || dateB == NSNull.null) {
            if (dateA != dateB) {
                return dateA != NSNull.null ? NSOrderedAscending : NSOrderedDescending;
            }
            return byName(indexA, indexB);
        }
        NSComparisonResult newestFirst = [(NSDate *)dateB compare:dateA];
        return newestFirst != NSOrderedSame ? newestFirst : byName(indexA, indexB);
    };
}

// Sorts urls in place by an order made over them as they stand.
static void VibeSortURLsByOrder(NSMutableArray<NSURL*> *urls, VibeURLOrder _Nullable urlOrder) {
    if (!urlOrder) {
        return;
    }
    NSUInteger count = urls.count;
    NSMutableArray<NSNumber*> *order = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger index = 0; index < count; index++) {
        [order addObject:@(index)];
    }
    [order sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        return urlOrder(a.unsignedIntegerValue, b.unsignedIntegerValue);
    }];
    NSArray<NSURL*> *unsorted = [urls copy];
    for (NSUInteger position = 0; position < count; position++) {
        urls[position] = unsorted[order[position].unsignedIntegerValue];
    }
}

static void VibeSortAudioURLs(NSMutableArray<NSURL*> *urls, VibeFolderOpenSort sort,
                              BOOL byFullPath) {
    VibeSortURLsByOrder(urls, VibeAudioURLOrder(urls, sort, byFullPath));
}

// What both listings prefetch. Every key is one more attribute the provider
// must answer, so the date is asked for only when the sort needs it; the size
// rides the same bulk read the stat keys already cost, and spares a stat per
// file (entriesForFile: reads it again for a FLAC).
static NSArray<NSURLResourceKey> *VibeListingKeys(VibeFolderOpenSort sort) {
    return sort == VibeFolderOpenSortNewestFirst
            ? @[NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey, NSURLFileSizeKey, NSURLContentModificationDateKey]
            : @[NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey, NSURLFileSizeKey];
}

// A listed file's emptiness, so a listed file costs the filter no stat: a
// link's from its target's stat, with *dangling set when the target is gone;
// any other file's from the size its listing prefetched, which is the logical
// size the test requires, never the allocated one. Anything it cannot stat
// passes, so the real open can report a sandbox denial.
static BOOL VibeListedFileIsEmpty(NSURL *url, BOOL isLink, BOOL *dangling) {
    *dangling = NO;
    if (isLink) {
        struct stat targetInfo;
        if (stat(url.fileSystemRepresentation, &targetInfo) == 0) {
            return VibeStatIsEmptyOrDirectory(&targetInfo);
        }
        // The link was just listed, so ENOENT means its target.
        *dangling = errno == ENOENT;
        return NO;
    }
    NSNumber *size = nil;
    if ([url getResourceValue:&size forKey:NSURLFileSizeKey error:NULL] && size != nil) {
        return size.longLongValue == 0;
    }
    return url.isEmptyOrDirectory;
}

// An enumeration failure, with the directory it met under NSURLErrorKey.
static NSError *VibeWalkFailure(NSURL *directory, NSError *error) {
    NSMutableDictionary<NSErrorUserInfoKey, id> *info = [error.userInfo mutableCopy] ?: [NSMutableDictionary dictionary];
    info[NSURLErrorKey] = directory;
    return [NSError errorWithDomain:error.domain code:error.code userInfo:info];
}

NSErrorDomain const VibeFolderScanErrorDomain = @"VibeFolderScanErrorDomain";

static NSError *VibeNotFetchedFailure(NSURL *directory) {
    return [NSError errorWithDomain:VibeFolderScanErrorDomain code:VibeFolderScanErrorNotFetched
                           userInfo:@{NSURLErrorKey: directory}];
}

// What a listing under the scan's policy fails with when the provider has
// not fetched the directory, in case the walk reaches one before its check.
static BOOL VibeErrorIsNotFetched(NSError *error) {
    for (NSError *e = error; e; e = e.userInfo[NSUnderlyingErrorKey]) {
        if ([e.domain isEqualToString:NSPOSIXErrorDomain] && e.code == EDEADLK) {
            return YES;
        }
    }
    return NO;
}


// Hands listed every directory deeper than depth, deepest first: an entry at
// that depth means they are listed in full. An empty one is skipped.
static void VibeCloseListedDirectories(NSMutableArray<NSMutableArray<NSURL *> *> *open, NSUInteger depth,
                                       void (^listed)(NSMutableArray<NSURL *> *files)) {
    while (open.count > depth) {
        NSMutableArray<NSURL *> *files = open.lastObject;
        [open removeLastObject];
        if (files.count > 0) {
            listed(files);
        }
    }
}

// The one enumerator, under the open and the scan alike: the nonempty audio
// files and the CUE sheets anywhere under dir, unsorted. With byDirectory,
// listed gets each directory's files once that directory is listed in full.
// Without it, listed gets every file once, in enumeration order. failures,
// when given, collects each directory the enumeration could not read. With
// skipsUnfetched, a directory the provider has not fetched is a failure of
// its own, and is not listed. A cancelled progress stops it between entries.
// It then reports nothing more and returns NO.
//
// The walk ranks each file through the walked-file handler on the way past,
// so the walked-directories handler gets each folder's best file for free.
// Only directories with playable audio are reported.
static BOOL VibeWalkTree(NSURL *dir, VibeFolderOpenSort sort, NSProgress *progress, BOOL byDirectory,
                         BOOL skipsUnfetched, NSMutableArray<NSError *> *failures,
                         void (^listed)(NSMutableArray<NSURL *> *files)) {

    NSMutableArray<NSURL*> *results = byDirectory ? nil : [[NSMutableArray alloc] init];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    VibeWalkedFileHandler rankFile = WalkedFileHandler();
    NSMutableDictionary<NSString*, NSString*> *keptByDirectory = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString*, NSNumber*> *keptRankByDirectory = [NSMutableDictionary dictionary];
    NSMutableSet<NSString*> *directoriesWalked = [NSMutableSet set];
    NSSet<NSString*> *supported = [FolderWalk supportedExtensions];

    // The enumerator neither follows a directory link nor takes one as root,
    // so each link found becomes another root, resolved to canonical form.
    // covered ends a link cycle and keeps a link into an already-walked
    // subtree from listing it twice.
    NSMutableArray<NSString*> *pendingRoots = [NSMutableArray array];
    NSMutableSet<NSString*> *covered = [NSMutableSet set];
    int rootError = 0;
    NSString *resolvedRoot = VibeResolvedDirectoryPath(dir.path, &rootError);
    if (resolvedRoot) {
        [pendingRoots addObject:resolvedRoot];
    }
    else if (failures) {
        [failures addObject:VibeWalkFailure(dir, [NSError errorWithDomain:NSPOSIXErrorDomain code:rootError
                                                                 userInfo:nil])];
    }

    // Skipping hidden files drops the AppleDouble "._Song.mp3" sidecars that
    // exFAT, SMB and USB volumes carry, which would pass the extension filter
    // as unplayable entries.
    NSArray<NSURLResourceKey> *keys = VibeListingKeys(sort);

    while (pendingRoots.count > 0) {
        NSString *rootPath = pendingRoots.firstObject;
        [pendingRoots removeObjectAtIndex:0];
        if ([covered containsObject:rootPath]) {
            continue;
        }
        [covered addObject:rootPath];
        if (skipsUnfetched && [PlaceholderFiles isDatalessDirectory:[NSURL fileURLWithPath:rootPath isDirectory:YES]]) {
            [failures addObject:VibeNotFetchedFailure([NSURL fileURLWithPath:rootPath isDirectory:YES])];
            continue;
        }
        // Held back until this root is enumerated in full, so each is tested
        // against everything it covered.
        NSMutableArray<NSString*> *linkedRoots = [NSMutableArray array];
        // Depth-first, so entries arrive in runs from one directory.
        NSString *lastDirectory = nil;
        // The directories still being listed, the root first, each with its
        // files so far. A directory's files are split around its subfolders,
        // so it is listed in full only when the walk climbs back above it.
        NSMutableArray<NSMutableArray<NSURL*>*> *open =
                byDirectory ? [NSMutableArray arrayWithObject:[NSMutableArray array]] : nil;
        NSDirectoryEnumerator *enumerator = [fileManager
                enumeratorAtURL:[NSURL fileURLWithPath:rootPath isDirectory:YES]
     includingPropertiesForKeys:keys
                        options:NSDirectoryEnumerationSkipsHiddenFiles | NSDirectoryEnumerationSkipsPackageDescendants
                   errorHandler:^(NSURL *url, NSError *error) {
                       if (skipsUnfetched && VibeErrorIsNotFetched(error)) {
                           [failures addObject:VibeNotFetchedFailure(url)];
                           return YES;
                       }
                       LogWarn(@"Error enumerating %@: %@", url, error);
                       if (failures) {
                           [failures addObject:VibeWalkFailure(url, error)];
                       }
                       return YES;
                   }];
        for (NSURL *url in enumerator) {
            if (progress.isCancelled) {
                return NO;
            }
            if (open) {
                VibeCloseListedDirectories(open, enumerator.level, listed);
            }
            NSError *error = nil;
            NSNumber *isDirectory = nil;
            BOOL isFile;
            if ([url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:&error]) {
                isFile = !isDirectory.boolValue;
            }
            else {
                // Treat it as a file, so the extension filter still sees it.
                LogWarn(@"Could not read directory flag for %@: %@", url, error);
                isFile = YES;
            }
            // Every file reaches the walked-file handler below, audio or not.
            NSString *path = url.path;
            if (!isFile) {
                if (open) {
                    [open addObject:[NSMutableArray array]];
                }
                // Recorded so a link into this subtree reads as covered; one a
                // link already walked is skipped whole.
                if (path.length == 0) {
                    continue;
                }
                if ([covered containsObject:path]) {
                    [enumerator skipDescendants];
                }
                else {
                    [covered addObject:path];
                }
                // Before the enumerator descends, so the listing is never asked.
                if (skipsUnfetched && [PlaceholderFiles isDatalessDirectory:url]) {
                    [enumerator skipDescendants];
                    [failures addObject:VibeNotFetchedFailure(url)];
                }
                continue;
            }
            NSNumber *isLink = nil;
            [url getResourceValue:&isLink forKey:NSURLIsSymbolicLinkKey error:NULL];
            if (isLink.boolValue) {
                NSString *linked = VibeResolvedDirectoryPath(path, NULL);
                if (linked) {
                    [linkedRoots addObject:linked];
                    continue;
                }
            }
            NSString *extension = path.pathExtension.lowercaseString;
            BOOL isAudio = [supported containsObject:extension];
            BOOL empty = NO;
            if (isAudio || isLink.boolValue) {
                // A dangling link is dropped, or it would stay an unplayable entry.
                BOOL dangling;
                empty = VibeListedFileIsEmpty(url, isLink.boolValue, &dangling);
                if (dangling) {
                    continue;
                }
            }
            // A sheet sorts among the audio and stands in for its files
            // (entriesForWalk:); an M3U here would double what the walk found.
            if ((isAudio && !empty) || [VibePlaylistFile isCueExtension:extension]) {
                [results addObject:url];
                [open.lastObject addObject:url];
            }
            if (!VibePathIsDirectlyInside(path, lastDirectory)) {
                lastDirectory = path.stringByDeletingLastPathComponent;
            }
            if (lastDirectory.length > 0 && isAudio) {
                [directoriesWalked addObject:lastDirectory];
            }
            NSString *filename = path.lastPathComponent;
            NSUInteger rank = rankFile && lastDirectory.length > 0 ? rankFile(filename) : NSNotFound;
            // NSNotFound is NSIntegerMax, so it is tested, never compared.
            if (rank != NSNotFound) {
                NSNumber *kept = keptRankByDirectory[lastDirectory];
                if (kept == nil || rank < kept.unsignedIntegerValue) {
                    keptRankByDirectory[lastDirectory] = @(rank);
                    keptByDirectory[lastDirectory] = filename;
                }
            }
        }
        if (progress.isCancelled) {
            return NO;
        }
        if (open) {
            VibeCloseListedDirectories(open, 0, listed);
        }

        for (NSString *linked in linkedRoots) {
            if (![covered containsObject:linked]) {
                [pendingRoots addObject:linked];
            }
        }
    }

    VibeWalkedDirectoriesHandler walked = WalkedDirectoriesHandler();
    if (walked && directoriesWalked.count > 0) {
        walked(directoriesWalked, keptByDirectory);
    }
    if (results) {
        listed(results);
    }
    return YES;
}

// The nonempty audio under dir, sorted, as entries handed to emit in order.
// The whole tree is listed and its sheets read before the first entry leaves,
// since a sheet anywhere can claim any file. The first entry is then found in
// one pass, and leaves before the rest is sorted. A cancelled progress stops
// the listing between entries. NO when the progress or emit stopped it.
static BOOL VibeEmitExpandedDirectory(NSURL *dir, VibeFolderOpenSort sort, NSProgress *_Nullable progress,
                                      VibeEntriesSink emit);

+ (NSArray<VibePlaylistEntry*>*) expandDirectory:(NSURL*)dir sortedBy:(VibeFolderOpenSort)sort {
    NSMutableArray<VibePlaylistEntry *> *entries = [NSMutableArray array];
    VibeEmitExpandedDirectory(dir, sort, nil, ^BOOL(NSArray<VibePlaylistEntry *> *made) {
        [entries addObjectsFromArray:made];
        return YES;
    });
    return entries;
}

typedef NS_ENUM(NSInteger, VibeReadAccess) {
    VibeReadAccessReadable,
    VibeReadAccessMissing,
    VibeReadAccessDenied,
};

// access(2), because only its errno tells missing from sandbox-denied, and
// only denied is worth a grant prompt.
static VibeReadAccess ReadAccessForURL(NSURL *url) {
    if (access(url.fileSystemRepresentation, R_OK) == 0) {
        return VibeReadAccessReadable;
    }
    return (errno == EPERM || errno == EACCES) ? VibeReadAccessDenied : VibeReadAccessMissing;
}

// TRAP: a remote placeholder is asked first. Its mode denies its owner, and
// access(2) calls it denied. A playlist naming one would then raise a grant
// panel. It plays: the player downloads it.
static VibeReadAccess PlaylistEntryAccess(NSURL *url) {
    return [PlaceholderFiles isRemotePlaceholderFile:url] ? VibeReadAccessReadable : ReadAccessForURL(url);
}

+ (BOOL)isReadDenied:(NSURL *)url {
    return ReadAccessForURL(url) == VibeReadAccessDenied;
}

// The files a sheet may name, by VibePlaylistFile's key, from one listing.
static NSDictionary<NSString *, NSArray<NSURL *> *> *VibeKnownFiles(NSArray<NSURL *> *urls) {
    NSMutableDictionary<NSString *, NSMutableArray<NSURL *> *> *knownFiles =
            [NSMutableDictionary dictionaryWithCapacity:urls.count];
    for (NSURL *url in urls) {
        NSString *key = [VibePlaylistFile knownFileKeyForPath:url.path];
        NSMutableArray<NSURL *> *matches = knownFiles[key];
        if (!matches) {
            knownFiles[key] = matches = [NSMutableArray array];
        }
        [matches addObject:url];
    }
    return knownFiles;
}

// A sheet's entries that name supported, nonempty files, listed or readable: a
// listed placeholder counts though no readability probe passes it. playable
// holds the verdict once per file, however many entries or sheets name it.
// failures, when given, collects each file a denial kept out, with its
// directory. Background work never asks for a grant, so a scan reports one.
static NSArray<VibePlaylistEntry *> *VibePlayableSheetEntries(NSURL *sheet, NSSet<NSURL *> *listed,
                                                         NSDictionary<NSString *, NSArray<NSURL *> *> *knownFiles,
                                                         NSMutableDictionary<NSURL *, NSNumber *> *playable,
                                                         NSMutableArray<NSError *> *failures) {
    NSSet<NSString *> *supported = PlayableExtensions.lookup;
    NSMutableArray<VibePlaylistEntry *> *entries = [NSMutableArray array];
    for (VibePlaylistEntry *entry in [VibePlaylistFile cueEntriesForSheetAtURL:sheet knownFiles:knownFiles]) {
        NSNumber *verdict = playable[entry.url];
        if (verdict == nil) {
            BOOL readable = [supported containsObject:entry.url.pathExtension.lowercaseString]
                    && !entry.url.isEmptyOrDirectory;
            if (readable && ![listed containsObject:entry.url]) {
                VibeReadAccess access = ReadAccessForURL(entry.url);
                readable = access == VibeReadAccessReadable;
                if (access == VibeReadAccessDenied && failures) {
                    [failures addObject:[NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoPermissionError
                                                        userInfo:@{NSURLErrorKey: entry.url.URLByDeletingLastPathComponent,
                                                                   NSFilePathErrorKey: entry.url.path ?: @""}]];
                }
            }
            verdict = @(readable);
            playable[entry.url] = verdict;
        }
        if (verdict.boolValue) {
            [entries addObject:entry];
        }
    }
    return entries;
}

// The first unread sheet by path, or nil with none.
static NSURL *_Nullable VibeFirstUnreadSheet(NSSet<NSURL *> *unreadSheets) {
    return [unreadSheets.allObjects sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        return [a.path compare:b.path];
    }].firstObject;
}

// Each entry beside the sheet, or the entries as they are with none.
static NSArray<VibePlaylistEntry *> *VibeEntriesBesideSheet(NSArray<VibePlaylistEntry *> *entries,
                                                           NSURL *_Nullable sheet) {
    if (!sheet) {
        return entries;
    }
    NSMutableArray<VibePlaylistEntry *> *beside = [NSMutableArray arrayWithCapacity:entries.count];
    for (VibePlaylistEntry *entry in entries) {
        [beside addObject:[entry entryBesideUnreadCueSheet:sheet]];
    }
    return beside;
}

// Reads the sheets among sheetsInOrder, in that order, against the listing
// urls. Where two sheets name one file, the first claims it, so the order
// must be the walk's.
static VibeWalkSheets *VibeReadWalkSheets(NSArray<NSURL *> *urls, NSArray<NSURL *> *sheetsInOrder,
                                          NSMutableArray<NSError *> *failures, BOOL readsPlaceholderSheets) {
    VibeWalkSheets *read = [VibeWalkSheets new];
    NSMutableArray<NSURL *> *sheets = [NSMutableArray array];
    read.unreadSheets = [NSMutableSet set];
    for (NSURL *url in sheetsInOrder) {
        if ([VibePlaylistFile isCueExtension:url.pathExtension.lowercaseString]) {
            if (readsPlaceholderSheets || ![PlaceholderFiles isDatalessFile:url]) {
                [sheets addObject:url];
            }
            else {
                [read.unreadSheets addObject:url];
            }
        }
    }
    read.unread = VibeFirstUnreadSheet(read.unreadSheets);
    read.entriesBySheet = [NSMutableDictionary dictionary];
    read.claimed = [NSMutableDictionary dictionary];
    if (sheets.count > 0) {
        NSSet<NSURL *> *listed = [NSSet setWithArray:urls];
        NSDictionary<NSString *, NSArray<NSURL *> *> *knownFiles = VibeKnownFiles(urls);
        NSMutableDictionary<NSURL *, NSNumber *> *playable = [NSMutableDictionary dictionary];
        for (NSURL *sheet in sheets) {
            NSMutableArray<VibePlaylistEntry *> *entries = [NSMutableArray array];
            for (VibePlaylistEntry *entry in VibePlayableSheetEntries(sheet, listed, knownFiles, playable, failures)) {
                NSURL *cutBy = read.claimed[entry.url];
                if (!cutBy || cutBy == sheet) {
                    [entries addObject:entry];
                    read.claimed[entry.url] = sheet;
                }
            }
            read.entriesBySheet[sheet] = entries;
        }
    }
    return read;
}

// What url plays as: a sheet's entries, nothing for a claimed file or an
// unread sheet, else the file's own entries. Only the last reads anything.
static NSArray<VibePlaylistEntry *> *VibeWalkEntriesOf(NSURL *url, VibeWalkSheets *sheets) {
    NSArray<VibePlaylistEntry *> *entries = sheets.entriesBySheet[url];
    if (!entries && !sheets.claimed[url] && ![sheets.unreadSheets containsObject:url]) {
        entries = [FolderWalk entriesForFile:url];
    }
    return entries;
}

// urls' entries in order, skipping the url already handed over.
static BOOL VibeEmitWalkEntries(NSArray<NSURL *> *urls, VibeWalkSheets *sheets, NSURL *_Nullable handedOver,
                                VibeEntriesSink emit) {
    for (NSURL *url in urls) {
        if (url == handedOver) {
            continue;
        }
        NSArray<VibePlaylistEntry *> *entries = VibeWalkEntriesOf(url, sheets);
        if (entries.count > 0 && !emit(VibeEntriesBesideSheet(entries, sheets.unread))) {
            return NO;
        }
    }
    return YES;
}

// Each audio file its entries (entriesForFile:), and each sheet its entries in
// its sorted place. A sheet resolves against the walk's own listing first and
// claims its files, so none also appears whole or is opened for its own sheet,
// and none is cut again by a later sheet: Album.cue beside Album (UTF-8).cue
// would list every track twice. Sheet entries must name supported, nonempty
// files, listed or readable. failures as VibePlayableSheetEntries takes it.
// Without readsPlaceholderSheets, a sheet that is a cloud placeholder is not
// read, since the read would download it. Background work must not download.
// It is no entry of its own. Every other entry of the call names it as its
// unread sheet, the first by path, so a caller that splits them into
// batches still knows each one's windows are unknown.
//
// Every sheet is read and its claims settled before the first entry leaves,
// so the entries emit hands over are the ones the whole call would make.
static BOOL VibeEmitEntriesForWalk(NSArray<NSURL *> *urls, NSMutableArray<NSError *> *failures,
                                   BOOL readsPlaceholderSheets, VibeEntriesSink emit) {
    return VibeEmitWalkEntries(urls, VibeReadWalkSheets(urls, urls, failures, readsPlaceholderSheets), nil, emit);
}

// The position of the url whose entries a sorted walk hands over first, or
// NSNotFound when none has any, or when another ties with it, since the sort
// may then put either first. That url sorts before every other with entries.
// One that sorts before it has none: a claimed file or a sheet that cut
// nothing. A sheet always has its entries already, and a file that is not
// claimed always makes at least one, so no file is read to answer.
static NSUInteger VibeFirstWalkEntryIndex(NSArray<NSURL *> *urls, VibeWalkSheets *sheets, VibeURLOrder order) {
    NSUInteger first = NSNotFound;
    BOOL tied = NO;
    for (NSUInteger index = 0; index < urls.count; index++) {
        NSURL *url = urls[index];
        NSArray<VibePlaylistEntry *> *sheetEntries = sheets.entriesBySheet[url];
        BOOL hasEntries = sheetEntries ? sheetEntries.count > 0
                                       : !sheets.claimed[url] && ![sheets.unreadSheets containsObject:url];
        if (!hasEntries) {
            continue;
        }
        NSComparisonResult result = first == NSNotFound ? NSOrderedAscending : order(index, first);
        if (result == NSOrderedAscending) {
            first = index;
            tied = NO;
        }
        else if (result == NSOrderedSame) {
            tied = YES;
        }
    }
    return tied ? NSNotFound : first;
}

static NSArray<VibePlaylistEntry *> *VibeEntriesForWalk(NSArray<NSURL *> *urls, NSMutableArray<NSError *> *failures,
                                                   BOOL readsPlaceholderSheets) {
    NSMutableArray<VibePlaylistEntry *> *entries = [NSMutableArray arrayWithCapacity:urls.count];
    VibeEmitEntriesForWalk(urls, failures, readsPlaceholderSheets, ^BOOL(NSArray<VibePlaylistEntry *> *made) {
        [entries addObjectsFromArray:made];
        return YES;
    });
    return entries;
}

static BOOL VibeEmitExpandedDirectory(NSURL *dir, VibeFolderOpenSort sort, NSProgress *_Nullable progress,
                                      VibeEntriesSink emit) {
    __block NSMutableArray<NSURL *> *listed = nil;
    BOOL walked = VibeWalkTree(dir, sort, progress, NO, NO, nil, ^(NSMutableArray<NSURL *> *files) {
        listed = files;
    });
    if (!walked) {
        return NO;
    }
    listed = listed ?: [NSMutableArray array];
    VibeURLOrder order = VibeAudioURLOrder(listed, sort, YES);
    if (!order) {
        return VibeEmitEntriesForWalk(listed, nil, YES, emit);
    }
    // The sheets alone, sorted, claim as they would in the whole sorted walk,
    // since only their order among themselves decides a claim. Two that tie
    // could sort either way, so they wait for the whole sort.
    NSMutableArray<NSNumber *> *sheetPositions = [NSMutableArray array];
    for (NSUInteger index = 0; index < listed.count; index++) {
        if ([VibePlaylistFile isCueExtension:listed[index].pathExtension.lowercaseString]) {
            [sheetPositions addObject:@(index)];
        }
    }
    [sheetPositions sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        return order(a.unsignedIntegerValue, b.unsignedIntegerValue);
    }];
    NSMutableArray<NSURL *> *sheetsInOrder = [NSMutableArray arrayWithCapacity:sheetPositions.count];
    BOOL sheetsTie = NO;
    for (NSUInteger position = 0; position < sheetPositions.count; position++) {
        [sheetsInOrder addObject:listed[sheetPositions[position].unsignedIntegerValue]];
        sheetsTie |= position > 0 && order(sheetPositions[position - 1].unsignedIntegerValue,
                                           sheetPositions[position].unsignedIntegerValue) == NSOrderedSame;
    }
    // The first entry leaves before the whole sort, which is most of what a
    // large tree waits for once it is listed.
    VibeWalkSheets *sheets = nil;
    NSURL *handedOver = nil;
    if (!sheetsTie) {
        sheets = VibeReadWalkSheets(listed, sheetsInOrder, nil, YES);
        NSUInteger first = VibeFirstWalkEntryIndex(listed, sheets, order);
        if (first != NSNotFound) {
            handedOver = listed[first];
            NSArray<VibePlaylistEntry *> *entries = VibeWalkEntriesOf(handedOver, sheets);
            if (entries.count > 0 && !emit(VibeEntriesBesideSheet(entries, sheets.unread))) {
                return NO;
            }
        }
    }
    VibeSortURLsByOrder(listed, order);
    sheets = sheets ?: VibeReadWalkSheets(listed, listed, nil, YES);
    return VibeEmitWalkEntries(listed, sheets, handedOver, emit);
}

+ (NSArray<NSURL *> *)sortedListingOfDirectory:(NSURL *)dir sortedBy:(VibeFolderOpenSort)sort {
    __block NSMutableArray<NSURL *> *listed = nil;
    VibeWalkTree(dir, sort, nil, NO, NO, nil, ^(NSMutableArray<NSURL *> *files) {
        listed = files;
    });
    listed = listed ?: [NSMutableArray array];
    VibeSortAudioURLs(listed, sort, YES);
    return listed;
}

+ (NSArray<VibePlaylistEntry *> *)entriesForWalk:(NSArray<NSURL *> *)urls {
    return VibeEntriesForWalk(urls, nil, YES);
}

// A whole album or mix in one FLAC may carry its own sheet, and only such a
// file is opened to look: an ordinary track is under the size, and a cloud
// placeholder is never read, since the read would download it. The gate keeps
// a walk's only content reads to a few files even on a network volume.
static const long long kVibeEmbeddedCueMinimumBytes = 100LL * 1024 * 1024;

static NSMutableArray<NSURL *> *VibeListedAudioURLs(NSURL *dir, VibeFolderOpenSort sort,
                                                  NSMutableArray<NSURL *> *subfolders,
                                                  NSMutableArray<NSURL *> *playlists);

+ (NSArray<VibePlaylistEntry *> *)entriesForFile:(NSURL *)url {
    // A sheet alone resolves against its folder's listing, as a walk does,
    // and claims nothing from its siblings: picked, it is the user's choice.
    if ([VibePlaylistFile isCueExtension:url.pathExtension.lowercaseString]) {
        NSArray<NSURL *> *listed = VibeListedAudioURLs(url.URLByDeletingLastPathComponent,
                                                       VibeFolderOpenSortAsReceived, nil, nil) ?: @[];
        return VibePlayableSheetEntries(url, [NSSet setWithArray:listed], VibeKnownFiles(listed),
                                        [NSMutableDictionary dictionary], nil);
    }
    if ([VibePlaylistFile isM3UExtension:url.pathExtension.lowercaseString]) {
        return [self expandFileList:@[url] sortedBy:VibeFolderOpenSortAsReceived folderCount:NULL
               looseFileDirectories:nil expandedCount:NULL];
    }
    if ([url.pathExtension.lowercaseString isEqualToString:@"flac"]) {
        NSNumber *size = nil;
        [url getResourceValue:&size forKey:NSURLFileSizeKey error:NULL];
        if (size.longLongValue >= kVibeEmbeddedCueMinimumBytes && ![PlaceholderFiles isDatalessFile:url]) {
            VibeEmbeddedSheetRead read = ^NSArray<VibePlaylistEntry *> *{
                return [VibePlaylistFile cueEntriesEmbeddedInFLACAtURL:url];
            };
            VibeEmbeddedSheetReadHandler handler = EmbeddedSheetReadHandler();
            NSArray<VibePlaylistEntry *> *entries = handler ? handler(url, sScanning, read) : read();
            if (entries.count > 0) {
                return entries;
            }
        }
    }
    return @[[VibePlaylistEntry entryWithURL:url]];
}

// The folder's nonempty audio files and sheets, listed with the keys `sort`
// needs, unsorted; nil when the listing fails. `subfolders` and `playlists`,
// when given, take the directories and the nonempty M3U files of the same
// enumeration: a provider's listing is IPC, and a browser screen asking twice
// paid for it twice.
static NSMutableArray<NSURL *> *VibeListedAudioURLs(NSURL *dir, VibeFolderOpenSort sort,
                                                  NSMutableArray<NSURL *> *subfolders,
                                                  NSMutableArray<NSURL *> *playlists) {
    // Skipping hidden files drops AppleDouble sidecars.
    NSError *error = nil;
    NSArray<NSURL*> *contents = [[NSFileManager defaultManager]
            contentsOfDirectoryAtURL:dir
          includingPropertiesForKeys:VibeListingKeys(sort)
                             options:NSDirectoryEnumerationSkipsHiddenFiles
                               error:&error];
    if (!contents) {
        LogWarn(@"Error listing %@: %@", dir, error);
        return nil;
    }
    NSSet<NSString*> *supported = PlayableExtensions.lookup;
    NSMutableArray<NSURL*> *results = [[NSMutableArray alloc] init];
    for (NSURL *url in contents) {
        NSString *extension = url.pathExtension.lowercaseString;
        // The key is one of the listing's (VibeListingKeys): no I/O per entry.
        NSNumber *isDirectory = nil;
        [url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:NULL];
        if (isDirectory.boolValue) {
            [subfolders addObject:url];
            continue;
        }
        // An M3U is never an entry of its folder: it would double what the
        // folder plays.
        BOOL m3u = playlists && [VibePlaylistFile isM3UExtension:extension];
        if (![supported containsObject:extension] && ![VibePlaylistFile isCueExtension:extension] && !m3u) {
            continue;
        }
        NSNumber *isLink = nil;
        [url getResourceValue:&isLink forKey:NSURLIsSymbolicLinkKey error:NULL];
        BOOL dangling = NO;
        if (!VibeListedFileIsEmpty(url, isLink.boolValue, &dangling) && !dangling) {
            [m3u ? playlists : results addObject:url];
        }
    }
    return results;
}

+ (NSArray<VibePlaylistEntry*>*) entriesInDirectory:(NSURL*)dir sortedBy:(VibeFolderOpenSort)sort {
    NSMutableArray<NSURL *> *results = VibeListedAudioURLs(dir, sort, nil, nil);
    if (!results) {
        return @[];
    }
    VibeSortAudioURLs(results, sort, NO);
    return [self entriesForWalk:results];
}

+ (void)listDirectory:(NSURL *)dir
             sortedBy:(VibeFolderOpenSort)sort
              folders:(NSArray<NSURL *> **)folders
            playlists:(NSArray<NSURL *> **)playlists
                audio:(NSArray<NSURL *> **)audio {
    NSMutableArray<NSURL *> *subfolders = folders ? [NSMutableArray array] : nil;
    NSMutableArray<NSURL *> *m3us = playlists ? [NSMutableArray array] : nil;
    NSMutableArray<NSURL *> *files = VibeListedAudioURLs(dir, sort, subfolders, m3us) ?: [NSMutableArray array];
    if (folders) {
        VibeSortAudioURLs(subfolders, sort, NO);
        *folders = subfolders;
    }
    if (playlists) {
        VibeSortAudioURLs(m3us, sort, NO);
        *playlists = m3us;
    }
    VibeSortAudioURLs(files, sort, NO);
    if (audio) {
        *audio = files;
    }
}

// Concurrent, so one dead mount cannot hold every later open; bounded, so a
// burst of blocked walks cannot spawn a thread each. Callers order overlapping
// results.
+ (NSOperationQueue *)expansionQueue {
    static NSOperationQueue *queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = [[NSOperationQueue alloc] init];
        queue.name = @"vibe-libs.folderscan.expansion";
        queue.maxConcurrentOperationCount = 4;
        queue.qualityOfService = NSQualityOfServiceUserInitiated;
    });
    return queue;
}

+ (void) expandAndFilterList:(NSArray<NSURL*>*)list
                    sortedBy:(VibeFolderOpenSort)sort
                  completion:(void (^)(NSArray<VibePlaylistEntry*>*, NSUInteger))completion {
    [[self expansionQueue] addOperationWithBlock:^{
        NSUInteger folderCount = 0;
        NSArray<VibePlaylistEntry*> *results = [self expandAndFilterList:list sortedBy:sort
                                                             folderCount:&folderCount];
        completion(results, folderCount);
    }];
}

const NSUInteger VibeFolderScanBatchLimit = 256;

+ (void)expandAndFilterList:(NSArray<NSURL *> *)list
                   sortedBy:(VibeFolderOpenSort)sort
                   progress:(NSProgress *)progress
                      batch:(void (^)(NSArray<VibePlaylistEntry *> *entries))batch
                 completion:(void (^)(NSUInteger folderCount))completion {
    [[self expansionQueue] addOperationWithBlock:^{
        NSMutableArray<VibePlaylistEntry *> *pending = [NSMutableArray array];
        __block BOOL handedOver = NO;
        BOOL (^flush)(void) = ^BOOL {
            if (progress.isCancelled) {
                return NO;
            }
            if (pending.count > 0) {
                NSArray<VibePlaylistEntry *> *entries = [pending copy];
                [pending removeAllObjects];
                handedOver = YES;
                batch(entries);
                progress.completedUnitCount += (int64_t)entries.count;
            }
            return !progress.isCancelled;
        };
        // The first entry leaves alone, as soon as it is made.
        VibeEntriesSink emit = ^BOOL(NSArray<VibePlaylistEntry *> *entries) {
            for (VibePlaylistEntry *entry in entries) {
                [pending addObject:entry];
                if ((!handedOver || pending.count >= VibeFolderScanBatchLimit) && !flush()) {
                    return NO;
                }
            }
            return !progress.isCancelled;
        };
        NSUInteger folderCount = 0;
        if ([self emitAndFilterList:list sortedBy:sort progress:progress folderCount:&folderCount emit:emit]) {
            flush();
        }
        completion(folderCount);
    }];
}

// Utility QoS, off the open's four workers: a scan stuck on a dead mount holds
// no open back.
+ (void)scanRoots:(NSArray<NSURL *> *)roots
       readPolicy:(VibeFolderScanReadPolicy)policy
         progress:(NSProgress *)progress
            batch:(void (^)(NSArray<VibePlaylistEntry *> *))batch
       completion:(void (^)(NSArray<NSNumber *> *, NSArray<NSArray<NSError *> *> *))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSMutableArray<NSArray<NSError *> *> *failureLists = [NSMutableArray arrayWithCapacity:roots.count];
        NSMutableArray<NSNumber *> *verdicts = [NSMutableArray arrayWithCapacity:roots.count];
        sScanning = YES;
        VibeWithoutMaterializing(@"a scan", ^{ for (NSURL *root in roots) {
            NSMutableArray<NSError *> *failures = [NSMutableArray array];
            if (!progress.isCancelled) {
                VibeWalkTree(root, VibeFolderOpenSortAsReceived, progress, YES, YES, failures,
                             ^(NSMutableArray<NSURL *> *files) {
                    NSMutableArray<VibePlaylistEntry *> *entries = [NSMutableArray arrayWithCapacity:files.count];
                    if (policy == VibeFolderScanReadPolicyLocal) {
                        [entries addObjectsFromArray:VibeEntriesForWalk(files, failures, NO)];
                    }
                    else {
                        for (NSURL *file in files) {
                            [entries addObject:[VibePlaylistEntry entryWithURL:file]];
                        }
                    }
                    for (NSUInteger start = 0; start < entries.count; start += VibeFolderScanBatchLimit) {
                        if (progress.isCancelled) {
                            return;
                        }
                        NSUInteger length = MIN(VibeFolderScanBatchLimit, entries.count - start);
                        batch([entries subarrayWithRange:NSMakeRange(start, length)]);
                        progress.completedUnitCount += (int64_t)length;
                    }
                });
            }
            [failureLists addObject:failures];
            [verdicts addObject:@(failures.count > 0 ? VibeFolderScanVerdictPartial : VibeFolderScanVerdictComplete)];
        } });
        sScanning = NO;
        if (progress.isCancelled) {
            for (NSUInteger index = 0; index < verdicts.count; index++) {
                verdicts[index] = @(VibeFolderScanVerdictCancelled);
            }
        }
        completion(verdicts, failureLists);
    });
}

+ (NSArray<VibePlaylistEntry*>*) expandAndFilterList:(NSArray<NSURL*>*)list
                                            sortedBy:(VibeFolderOpenSort)sort
                                         folderCount:(NSUInteger *)folderCount {
    NSMutableArray<VibePlaylistEntry *> *entries = [NSMutableArray array];
    [self emitAndFilterList:list sortedBy:sort progress:nil folderCount:folderCount
                       emit:^BOOL(NSArray<VibePlaylistEntry *> *made) {
                           [entries addObjectsFromArray:made];
                           return YES;
                       }];
    return entries;
}

// The expansion, handed to emit in order, then the bulk open's folders. NO
// when the progress or emit stopped it, and then no handler hears of it.
+ (BOOL)emitAndFilterList:(NSArray<NSURL *> *)list
                 sortedBy:(VibeFolderOpenSort)sort
                 progress:(nullable NSProgress *)progress
              folderCount:(nullable NSUInteger *)folderCount
                     emit:(VibeEntriesSink)emit {
    NSUInteger inputCount = list.count;
    NSMutableSet<NSString*> *looseFileDirectories = [NSMutableSet set];
    NSMutableSet<NSString *> *supportedLooseDirectories = [NSMutableSet set];
    NSUInteger expandedCount = 0;
    NSUInteger folders = 0;
    BOOL finished = [self emitFileList:list sortedBy:sort progress:progress folderCount:&folders
                  looseFileDirectories:looseFileDirectories
                         expandedCount:&expandedCount
                                  emit:^BOOL(NSArray<VibePlaylistEntry *> *entries) {
                                      for (VibePlaylistEntry *entry in entries) {
                                          [self noteLooseFileDirectoryOf:entry.url into:supportedLooseDirectories];
                                      }
                                      return emit(entries);
                                  }];
    if (folderCount) {
        *folderCount = folders;
    }
    if (!finished) {
        return NO;
    }
    [looseFileDirectories intersectSet:supportedLooseDirectories];
    // Anything but a single file is a bulk open, whose loose files' folders are
    // worth a listing each. The post-expansion count matters: a dropped .cue is
    // one file naming a whole album.
    BOOL bulkOpen = inputCount > 1 || folders > 0 || looseFileDirectories.count > 1 || expandedCount > inputCount;
    VibeBulkOpenDirectoriesHandler bulk = BulkOpenDirectoriesHandler();
    if (bulkOpen && bulk && looseFileDirectories.count > 0) {
        bulk(looseFileDirectories);
    }
    return YES;
}

+ (NSArray<VibePlaylistEntry*>*) expandFileList:(NSArray<NSURL*>*)list
                                       sortedBy:(VibeFolderOpenSort)sort
                                    folderCount:(NSUInteger *)folderCount
                           looseFileDirectories:(NSMutableSet<NSString*> *)looseFileDirectories
                                  expandedCount:(NSUInteger *)expandedCount {
    NSMutableArray<VibePlaylistEntry*> *results = [[NSMutableArray alloc] initWithCapacity:list.count];
    [self emitFileList:list sortedBy:sort progress:nil folderCount:folderCount
        looseFileDirectories:looseFileDirectories
               expandedCount:expandedCount
                        emit:^BOOL(NSArray<VibePlaylistEntry *> *entries) {
                            [results addObjectsFromArray:entries];
                            return YES;
                        }];
    return results;
}

// Each item in the order given, as its playable entries handed to emit. NO
// when the progress or emit stopped it.
+ (BOOL)emitFileList:(NSArray<NSURL *> *)list
            sortedBy:(VibeFolderOpenSort)sort
            progress:(nullable NSProgress *)progress
         folderCount:(nullable NSUInteger *)folderCount
looseFileDirectories:(nullable NSMutableSet<NSString *> *)looseFileDirectories
       expandedCount:(nullable NSUInteger *)expandedCount
                emit:(VibeEntriesSink)emit {
    NSSet<NSString*> *supported = [FolderWalk supportedExtensions];
    // Nothing can play an empty file. Second, so only extension matches pay
    // the stat, once per file however many entries it has. A walk's entries
    // skip it: the walk drops what it would, unplayable names and empty files.
    NSMutableDictionary<NSURL*, NSNumber*> *playable = [NSMutableDictionary dictionary];
    BOOL (^emitPlayable)(NSArray<VibePlaylistEntry*> *) = ^BOOL(NSArray<VibePlaylistEntry*> *entries) {
        NSMutableArray<VibePlaylistEntry *> *kept = [NSMutableArray arrayWithCapacity:entries.count];
        for (VibePlaylistEntry *entry in entries) {
            NSNumber *verdict = playable[entry.url];
            if (verdict == nil) {
                verdict = @([supported containsObject:entry.url.pathExtension.lowercaseString]
                            && !entry.url.isEmptyOrDirectory);
                playable[entry.url] = verdict;
            }
            if (verdict.boolValue) {
                [kept addObject:entry];
            }
        }
        return kept.count == 0 || emit(kept);
    };
    NSUInteger expanded = 0;
    BOOL finished = YES;
    for (NSURL *url in list) {
        if (progress.isCancelled) {
            finished = NO;
            break;
        }
        // Ask the file system: hasDirectoryPath reads only the trailing slash,
        // which a URL from argv or some pasteboards lacks. The link flag rides
        // along, since a folder link must be resolved (VibeResolvedDirectoryPath).
        NSDictionary<NSURLResourceKey, id> *values =
                [url resourceValuesForKeys:@[NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey, NSURLFileSizeKey]
                                     error:NULL];
        NSNumber *isDirectory = values[NSURLIsDirectoryKey];
        BOOL isDir = isDirectory != nil
                ? isDirectory.boolValue
                : url.hasDirectoryPath; // resource read failed; fall back to the slash
        if (!isDir && [values[NSURLIsSymbolicLinkKey] boolValue]) {
            isDir = VibeResolvedDirectoryPath(url.path, NULL) != nil;
        }
        if (isDir) {
            if (folderCount) {
                (*folderCount)++;
            }
            __block NSUInteger count = 0;
            finished = VibeEmitExpandedDirectory(url, sort, progress, ^BOOL(NSArray<VibePlaylistEntry *> *entries) {
                count += entries.count;
                return emit(entries);
            });
            expanded += count;
        }
        else if ([VibePlaylistFile isPlaylistExtension:[url.pathExtension lowercaseString]]) {
            NSArray<VibePlaylistEntry*> *entries = [self expandPlaylistFile:url];
            expanded += entries.count;
            for (VibePlaylistEntry *entry in entries) {
                [self noteLooseFileDirectoryOf:entry.url into:looseFileDirectories];
            }
            finished = emitPlayable(entries);
        }
        else {
            NSArray<VibePlaylistEntry*> *entries = [self entriesForFile:url];
            expanded += entries.count;
            [self noteLooseFileDirectoryOf:url into:looseFileDirectories];
            finished = emitPlayable(entries);
        }
        if (!finished) {
            break;
        }
    }
    if (expandedCount) {
        *expandedCount = expanded;
    }
    return finished;
}

+ (void)noteLooseFileDirectoryOf:(NSURL *)url into:(NSMutableSet<NSString*> *)directories {
    NSString *directory = url.path.stringByDeletingLastPathComponent;
    if (directories && directory.length > 0) {
        [directories addObject:directory];
    }
}

#pragma mark - Playlist files (CUE, M3U)

// Only an explicitly opened playlist file expands here. A walk drops an M3U,
// because it would double every track. A walk's sheet goes to entriesForWalk:.
//
// Opening a playlist file grants access to it alone, so a denied entry raises
// one folder grant through the handler, and the re-resolve then also gets a
// working basename fallback. Entries still unreadable are skipped.
#if TARGET_OS_OSX
static VibePlaylistFolderGrantHandler PlaylistFolderGrantHandler(void) {
    @synchronized (FolderWalk.class) {
        return sPlaylistFolderGrantHandler;
    }
}
#endif

+ (NSArray<VibePlaylistEntry *> *)expandPlaylistFile:(NSURL *)playlistURL {
    NSArray<VibePlaylistEntry *> *resolved = [VibePlaylistFile entriesForPlaylistAtURL:playlistURL];
    // A probe can hang on a dead mount, so verdicts are reused by the filter
    // below, and dropped only when a grant changes readability. One per file,
    // however many entries a sheet cuts it into.
    NSMutableDictionary<NSString *, NSNumber *> *scannedAccessByPath =
            [NSMutableDictionary dictionaryWithCapacity:resolved.count];
#if TARGET_OS_OSX
    BOOL anyUnreadable = NO;
    BOOL anyDenied = NO;
    for (VibePlaylistEntry *entry in resolved) {
        NSURL *url = entry.url;
        if (scannedAccessByPath[url.path] != nil) {
            continue;
        }
        VibeReadAccess access = PlaylistEntryAccess(url);
        scannedAccessByPath[url.path] = @(access);
        anyUnreadable |= (access != VibeReadAccessReadable);
        anyDenied |= (access == VibeReadAccessDenied);
        if (anyUnreadable && anyDenied) {
            break;  // both facts settled; stop paying probes
        }
    }
    // With the playlist's own folder denied, "missing" cannot be trusted: the
    // fallback candidates beside the playlist could not be probed.
    BOOL folderDenied =
            ReadAccessForURL(playlistURL.URLByDeletingLastPathComponent) == VibeReadAccessDenied;
    VibePlaylistFolderGrantHandler grantHandler = PlaylistFolderGrantHandler();
    if (anyUnreadable && (anyDenied || folderDenied)
            && grantHandler && grantHandler(playlistURL)) {
        resolved = [VibePlaylistFile entriesForPlaylistAtURL:playlistURL];
        [scannedAccessByPath removeAllObjects];
    }
#endif
    NSMutableArray<VibePlaylistEntry *> *readable = [NSMutableArray arrayWithCapacity:resolved.count];
    NSMutableSet<NSString *> *skipped = [NSMutableSet set];
    for (VibePlaylistEntry *entry in resolved) {
        NSString *path = entry.url.path;
        NSNumber *scanned = scannedAccessByPath[path];
        VibeReadAccess access = scanned != nil ? (VibeReadAccess)scanned.integerValue : PlaylistEntryAccess(entry.url);
        scannedAccessByPath[path] = @(access);
        if (access == VibeReadAccessReadable) {
            [readable addObject:entry];
        }
        else if (![skipped containsObject:path]) {
            [skipped addObject:path];
            LogWarn(@"Skipping unreadable playlist entry: %@", path);
        }
    }
    LogInfo(@"Playlist file %@ expanded to %lu of %lu entries", playlistURL.lastPathComponent,
            (unsigned long)readable.count, (unsigned long)resolved.count);
    return readable;
}

@end
