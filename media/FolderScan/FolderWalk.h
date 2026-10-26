//
//  FolderWalk.h
//  vibe-libs
//

#import <Foundation/Foundation.h>

#import "FolderOpenSort.h"

NS_ASSUME_NONNULL_BEGIN

@class VibePlaylistEntry;

// Asks the user to grant the folder a playlist file's entries live in, and
// answers whether they did. Runs on an expansion worker and must block until
// answered. Unset (as in tests), unreadable entries are skipped.
typedef BOOL (^VibePlaylistFolderGrantHandler)(NSURL *playlistURL);

// What an expansion saw of the folders it touched. Unset, it is discarded.
// All three are called on an expansion worker.

// A file's rank, lower first, or NSNotFound to pass it over. A folder walk
// asks it for every file it lists, by name, and keeps the first best-ranked
// file of each directory. Unset, the walk keeps none.
typedef NSUInteger (^VibeWalkedFileHandler)(NSString *filename);

// The directories with playable audio, spelled as on disk, and the file kept
// in each, by name. Every directory was listed in full, so a directory with no
// kept file is an answer. Once per top-level folder expanded.
typedef void (^VibeWalkedDirectoriesHandler)(NSSet<NSString *> *directories,
                                             NSDictionary<NSString *, NSString *> *keptFilenameByDirectory);

// The loose files' folders in a bulk open, unlisted: only that a listing each
// is a fair price. Once per expansion; never for a single file.
typedef void (^VibeBulkOpenDirectoriesHandler)(NSSet<NSString *> *directories);

// What a catalog scan may read of a file's contents.
typedef NS_ENUM(NSInteger, VibeFolderScanReadPolicy) {
    // Nothing: every file is an entry whole, a CUE sheet included, and no
    // sheet or FLAC is opened.
    VibeFolderScanReadPolicyNone = 0,
    // What is local: each sheet beside the files that is not a cloud
    // placeholder, and the sheet inside a large FLAC that is not one. A
    // placeholder sheet is an entry whole, since the read would download it.
    // An open reads that sheet too.
    VibeFolderScanReadPolicyLocal,
};

// How much of one root a catalog scan saw. Only complete lets a catalog mark
// an unseen file missing.
typedef NS_ENUM(NSInteger, VibeFolderScanVerdict) {
    VibeFolderScanVerdictComplete = 0,
    // Something under the root could not be read. Its failures say what.
    VibeFolderScanVerdictPartial,
    // The token was cancelled before the scan ended.
    VibeFolderScanVerdictCancelled,
};

// No batch holds more entries than this.
FOUNDATION_EXPORT const NSUInteger VibeFolderScanBatchLimit;


@interface FolderWalk : NSObject

+ (void)setPlaylistFolderGrantHandler:(nullable VibePlaylistFolderGrantHandler)handler;
+ (void)setWalkedFileHandler:(nullable VibeWalkedFileHandler)handler;
+ (void)setWalkedDirectoriesHandler:(nullable VibeWalkedDirectoriesHandler)handler;
+ (void)setBulkOpenDirectoriesHandler:(nullable VibeBulkOpenDirectoriesHandler)handler;

// Expands folders and top-level playlist files to entries and filters to
// playable extensions, on a four-wide queue. Callers order overlapping
// results. A file is one entry; a CUE sheet — opened, or met
// in a walked folder, where it claims its files — is an entry per track.
// folderCount is how many top-level URLs were directories. Completion runs on
// the expansion worker, so the caller makes its rows off main.
//
// sort orders each expanded folder's audio only: top-level URLs and a playlist
// file's entries keep the order the user gave.
+ (void)expandAndFilterList:(NSArray<NSURL *> *)list
                   sortedBy:(VibeFolderOpenSort)sort
                 completion:(void (^)(NSArray<VibePlaylistEntry *> *entries, NSUInteger folderCount))completion;

// Every file under each root, in order, as entries, with nothing sorted. It
// runs at utility QoS on a worker of its own, never one of the open's four.
//
// batch runs on that worker with at most VibeFolderScanBatchLimit entries. A
// batch holds one directory's entries, in enumeration order, once that
// directory is listed in full, so its sheets have claimed their files. A
// large directory arrives in several batches.
//
// progress is the token. Cancelling it stops the scan between entries, and
// no batch starts after the cancel. The scan adds each batch's count to its
// completedUnitCount once the batch returns. It never sets the total.
//
// completion runs on the same worker once, after the last batch. It gives one
// verdict and one failure list per root, in the order of roots. Each failure
// is an NSError with the directory it met under NSURLErrorKey, in the order
// met. A root that cannot be read at all is partial with one failure naming
// it. A cancelled token makes every verdict cancelled.
//
// The scan never asks the grant handler, since background work must never
// raise a panel. The walked-file and walked-directories handlers run as they
// do under an open, once per root.
+ (void)scanRoots:(NSArray<NSURL *> *)roots
       readPolicy:(VibeFolderScanReadPolicy)policy
         progress:(NSProgress *)progress
            batch:(void (^)(NSArray<VibePlaylistEntry *> *entries))batch
       completion:(void (^)(NSArray<NSNumber *> *verdicts, NSArray<NSArray<NSError *> *> *failures))completion;

// Common/PlayableExtensions' set.
+ (NSSet<NSString *> *)supportedExtensions;

// One file as its entries: a CUE sheet's tracks, an M3U's readable entries, a
// large local FLAC's embedded cue sheet, else the file whole. Every expansion
// makes a file's entries here, so a sheet inside a file applies wherever the
// file is opened.
+ (NSArray<VibePlaylistEntry *> *)entriesForFile:(NSURL *)url;

// YES when the sandbox, not absence, keeps url from being read: the one case
// a grant would fix. A sheet's entriesForFile: is empty when it is the sheet's
// folder that is denied.
+ (BOOL)isReadDenied:(NSURL *)url;

// The folder's non-empty audio files as entries, non-recursive, hidden files
// skipped; a CUE sheet among them stands in for its files, as in a walk.
// Synchronous. sort is a parameter because this layer may not read a setting.
+ (NSArray<VibePlaylistEntry *> *)entriesInDirectory:(NSURL *)dir sortedBy:(VibeFolderOpenSort)sort;

// The folder's subfolders, its M3U playlists, and the audio files and sheets
// entriesInDirectory: would make entries of, each sorted by `sort`, hidden
// files skipped. What a browser draws, so a folder plays as it is shown; a playlist
// is not part of that, as a subfolder is not. Synchronous.
+ (void)listDirectory:(NSURL *)dir
             sortedBy:(VibeFolderOpenSort)sort
              folders:(NSArray<NSURL *> *_Nonnull *_Nullable)folders
            playlists:(NSArray<NSURL *> *_Nonnull *_Nullable)playlists
                audio:(NSArray<NSURL *> *_Nonnull *_Nullable)audio;
@end

NS_ASSUME_NONNULL_END
