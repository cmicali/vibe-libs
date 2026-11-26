//
//  VibeBrowserSubfolderWalk.h
//  vibe-libs
//
//  The walk behind a folder's "with subfolders" item: the folder and every
//  folder under it, listed up to four at once, with the folders that hold
//  songs handed back in depth-first order, as a walk of one folder at a time
//  would find them. Private to the browser.
//

#import <Foundation/Foundation.h>

#import "FolderOpenSort.h"
#import "VibeBrowserHost.h"

NS_ASSUME_NONNULL_BEGIN

// The walk stops after this many audio entries or visited folders, counted in
// depth-first order. Whole folders can pass the entry limit.
FOUNDATION_EXTERN const NSUInteger VibeBrowserMaximumSubfolderTracks;
FOUNDATION_EXTERN const NSUInteger VibeBrowserMaximumSubfolders;

@interface VibeBrowserSubfolderWalk : NSObject

// Lists folder and its subfolders. A folder a source lists from elsewhere,
// such as a Dropbox mirror's, is refreshed by that source before it is read,
// since a mirror holds only what something has listed. progress runs on main
// after each folder is listed, with how many folders were listed and how many
// songs they hold, including a few the caps may drop. completion runs once,
// on main: the folders with songs, and whether the caps left folders
// unvisited. The walk holds itself until it ends, so it finishes even when
// the screen that started it goes.
+ (void)walkFolder:(NSURL *)folder
            sortedBy:(VibeFolderOpenSort)sort
             sources:(NSArray<id<VibeBrowserSource>> *)sources
            progress:(void (^_Nullable)(NSUInteger listed, NSUInteger songs))progress
          completion:(void (^)(NSArray<NSURL *> *folders, BOOL capped))completion;

@end

NS_ASSUME_NONNULL_END
