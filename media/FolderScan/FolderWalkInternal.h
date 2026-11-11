//
//  FolderWalkInternal.h
//  vibe-libs
//
//  Synchronous expansion steps for FolderWalk.m, its tests and the bench harness.
//

#import "FolderWalk.h"

NS_ASSUME_NONNULL_BEGIN

@class VibePlaylistEntry;

@interface FolderWalk (Internal)

// The nonempty audio anywhere under dir as entries; Name sorts by full path,
// grouping subfolders.
+ (NSArray<VibePlaylistEntry *> *)expandDirectory:(NSURL *)dir sortedBy:(VibeFolderOpenSort)sort;

// The listing a walk of dir sorts, as listed.
+ (NSArray<NSURL *> *)listingOfDirectory:(NSURL *)dir sortedBy:(VibeFolderOpenSort)sort;

// The same listing sorted in full before any entry is made: what the walk's
// entries came from before it handed out its first one early.
+ (NSArray<NSURL *> *)sortedListingOfDirectory:(NSURL *)dir sortedBy:(VibeFolderOpenSort)sort;

// The position in a listing, as listed, of the url the walk hands over
// before the whole sort, or NSNotFound when it waits for the sort: under as
// received, when two paths with entries or two sheets tie, or when nothing
// has entries. order compares positions in urls.
+ (NSUInteger)firstEntryIndexOfListing:(NSArray<NSURL *> *)urls sortedBy:(VibeFolderOpenSort)sort;
+ (NSUInteger)firstEntryIndexOfListing:(NSArray<NSURL *> *)urls
                                 order:(NSComparisonResult (^)(NSUInteger a, NSUInteger b))order;

// The already-sorted listing, with sheets standing in for their audio files.
+ (NSArray<VibePlaylistEntry *> *)entriesForWalk:(NSArray<NSURL *> *)urls;

// Folders and top-level playlist files expanded in place, every entry
// playable. looseFileDirectories collects the folders of files not found by
// walking a folder; expandedCount, the entries before unplayable ones were
// dropped.
+ (NSArray<VibePlaylistEntry *> *)expandFileList:(NSArray<NSURL *> *)list
                                        sortedBy:(VibeFolderOpenSort)sort
                                     folderCount:(nullable NSUInteger *)folderCount
                            looseFileDirectories:(nullable NSMutableSet<NSString *> *)looseFileDirectories
                                   expandedCount:(nullable NSUInteger *)expandedCount;

+ (NSArray<VibePlaylistEntry *> *)expandAndFilterList:(NSArray<NSURL *> *)list
                                             sortedBy:(VibeFolderOpenSort)sort
                                          folderCount:(nullable NSUInteger *)folderCount;

@end

NS_ASSUME_NONNULL_END
