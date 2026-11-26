//
//  VibeBrowserHost.h
//  vibe-libs
//
//  The browser's folder screens as the app sees them. A folder screen names
//  no model class of the app's. It reads what its rows show from a host, and
//  every row and selection action is a value the host supplies: its title,
//  its glyph, and what it does with the rows. So one app offers Play and Add
//  to Playlist, and another offers Import. Its words, its sort setting, the
//  holders its art loads into, and the sources beside the granted folders
//  are the host's too.
//
//  Main thread only.
//

#import <UIKit/UIKit.h>

#import "FolderOpenSort.h"

@class AudioTrackMetadataCache;
@protocol AudioTrackMetadataHolder;
@protocol EqualizerLevelSource;

NS_ASSUME_NONNULL_BEGIN

// One action on rows. The handler gets the rows' URLs, in row order, and the
// screen they were on, which the app may present from.
@interface VibeBrowserAction : NSObject

+ (instancetype)actionWithTitle:(NSString *)title
                         symbol:(NSString *)symbol
                        handler:(void (^)(NSArray<NSURL *> *urls, UIViewController *screen))handler;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly, copy) NSString *title;
// An SF Symbol's name.
@property (nonatomic, readonly, copy) NSString *symbol;
@property (nonatomic, readonly, copy) void (^handler)(NSArray<NSURL *> *urls, UIViewController *screen);
// The rows go to the screen's addedRowsHandler before the handler runs.
@property (nonatomic) BOOL liftsRows;
// A bar button made from it shows the title as text in place of the glyph,
// such as an Import too plain to draw. NO by default. A swipe and a menu
// show both either way.
@property (nonatomic) BOOL showsTitle;

@end

// The browser's fixed words. Counted ones are methods of the host.
typedef NS_ENUM(NSInteger, VibeBrowserLabel) {
    VibeBrowserLabelSelect,           // the Select button's VoiceOver label
    VibeBrowserLabelSelectAll,
    VibeBrowserLabelSort,             // the sort button's VoiceOver label
    VibeBrowserLabelSortMenuTitle,
    VibeBrowserLabelFilter,           // the filter field's placeholder
    VibeBrowserLabelEmptyFolder,      // a folder with nothing to show or play
    VibeBrowserLabelUnavailable,      // a listing that could not be refreshed
    VibeBrowserLabelOK,
    VibeBrowserLabelLocations,        // the root's first group
    VibeBrowserLabelAddLocation,      // the plus's VoiceOver label
    VibeBrowserLabelAddFolder,        // the plus's item that grants a folder
    VibeBrowserLabelAddFolderCaption,
    VibeBrowserLabelLocationCovered,  // a granted folder some location covers
    VibeBrowserLabelRemoveLocation,
};

// A place the root lists before the granted folders: the app's Documents, a
// cloud mirror. Main thread only.
@protocol VibeBrowserSource <NSObject>
// Nil while it has nothing to show, such as a signed-out account. The root
// reads it when it reloads.
@property (nonatomic, readonly, nullable) NSURL *rootURL;
@property (nonatomic, readonly, copy) NSString *title;
@property (nonatomic, readonly, copy, nullable) NSString *subtitle;
@property (nonatomic, readonly) UIImage *image;
@optional
// Both or neither. A folder this source lists from elsewhere, such as a
// mirror, is drawn from disk and then refreshed. refreshesDirectoryURL:
// answers without touching the disk. The refresh completes on main, with nil
// or the reason the listing failed.
- (BOOL)refreshesDirectoryURL:(NSURL *)url;
- (void)refreshDirectoryURL:(NSURL *)url completion:(void (^)(NSError *_Nullable error))completion;
// What a folder of this source says when its refresh failed. The host's
// VibeBrowserLabelUnavailable without it.
@property (nonatomic, readonly, copy) NSString *unavailableMessage;
// Both or neither. The plus's item while rootURL is nil, such as Connect to
// Dropbox. connected runs on main once rootURL is there to show; a failure
// is the source's to report.
@property (nonatomic, readonly, copy) NSString *connectTitle;
- (void)connectFromScreen:(UIViewController *)screen connected:(dispatch_block_t)connected;
@end

// A source that is one folder, always there.
@interface VibeBrowserFolderSource : NSObject <VibeBrowserSource>
+ (instancetype)sourceWithRootURL:(NSURL *)rootURL title:(NSString *)title image:(UIImage *)image;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly) NSURL *rootURL;
@end

// One row the host adds to the root, below Locations.
@interface VibeBrowserRootRow : NSObject

+ (instancetype)rowWithTitle:(NSString *)title
                       image:(UIImage *)image
                     handler:(void (^)(UIViewController *screen))handler;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly, copy) NSString *title;
@property (nonatomic, readonly) UIImage *image;
// Gets the root it was tapped on, which the app may present from.
@property (nonatomic, readonly, copy) void (^handler)(UIViewController *screen);
// Drawn in the tint with no disclosure: the row does something, rather than
// going somewhere.
@property (nonatomic) BOOL isAction;
// The row spins in its icon slot.
@property (nonatomic) BOOL spinning;

@end

// What changed in the host. Each screen redraws what it shows, and answers
// only what it shows.
@protocol VibeBrowserHostObserver <NSObject>
@optional
- (void)browserHostPlayingFileDidChange;
- (void)browserHostPlayStateDidChange;
- (void)browserHostOpeningDidChange;
// A source came or went. The root reloads, and a screen of a source with no
// root left goes back to it.
- (void)browserHostSourcesDidChange;
// Files of a refreshing source changed on disk, such as a finished download.
- (void)browserHostSourceFilesDidChange;
// One of the host's rootSections changed. The root redraws it.
- (void)browserHostRootSectionDidChange:(NSUInteger)section animated:(BOOL)animated;
@end

@protocol VibeBrowserHost;

// The stack's one metadata cache, which the browser makes for the host the
// first time a row needs art. One per host, so one per stack of screens.
FOUNDATION_EXTERN AudioTrackMetadataCache *VibeBrowserArtCache(id<VibeBrowserHost> host);

// The first of sources that lists url from elsewhere, such as a Dropbox
// mirror, or nil. It never touches the disk.
FOUNDATION_EXTERN id<VibeBrowserSource> _Nullable VibeBrowserRefreshingSource(NSArray<id<VibeBrowserSource>> *sources,
                                                                             NSURL *url);

// An alert over screen with the host's OK. then runs on OK.
FOUNDATION_EXTERN void VibeBrowserPresentAlert(UIViewController *screen, id<VibeBrowserHost> host, NSString *title,
                                               NSString *message, dispatch_block_t _Nullable then);

@protocol VibeBrowserHost <NSObject>

#pragma mark Where the files are

// Listed first at the root, in order, before the granted folders.
@property (nonatomic, readonly, copy) NSArray<id<VibeBrowserSource>> *sources;

#pragma mark How the screens look and read

- (NSString *)label:(VibeBrowserLabel)label;
// The title while selecting, and the alert for a subfolder walk that stopped
// at its limit.
- (NSString *)selectionTitleForCount:(NSUInteger)count;
- (NSString *)subfoldersCappedMessageForLimit:(NSUInteger)limit;
// Over every folder screen's title, or nil for none.
@property (nonatomic, readonly, copy, nullable) NSString *prompt;
// Close at every level, for a stack presented as a sheet.
@property (nonatomic, readonly) BOOL showsCloseButton;
// The sort menu in the bar, which writes folderSort.
@property (nonatomic, readonly) BOOL showsSortMenu;
// The order every listing and walk uses. The sort menu writes it.
@property (nonatomic) VibeFolderOpenSort folderSort;
- (NSString *)titleForSort:(VibeFolderOpenSort)sort;

#pragma mark The actions

// A file row's tap, a second one on a spinning row included. A folder row's
// tap opens the folder.
- (void)screen:(UIViewController *)screen didTapFile:(NSURL *)url;
// Select's bar button and a row's swipe. Its rows are lifted when it says so.
@property (nonatomic, readonly) VibeBrowserAction *selectionAction;
// The bar button, on the folder shown.
@property (nonatomic, readonly) VibeBrowserAction *folderAction;
// The bar button's menu item: the folder shown with its subfolders. The host
// is asked when the user picks it, before the walk lists anything, with the
// folder the walk starts from, which may hold no songs itself, so it can show
// at once that something runs. The browser hands the folders with songs, in
// walk order, to the block returned. The walk finishes and calls the block
// even when the screen goes first, such as a sheet closed mid-walk: then it
// shows no alert, and a walk that found nothing calls nothing.
@property (nonatomic, readonly) NSString *subfoldersTitle;
- (void (^)(NSArray<NSURL *> *folders))subfoldersHandlerForFolder:(NSURL *)folder
                                                       fromScreen:(UIViewController *)screen;
// A row's long press. Asked each time the menu opens.
- (NSArray<VibeBrowserAction *> *)menuActionsForURL:(NSURL *)url isFolder:(BOOL)isFolder;

@optional

// Groups below Locations, asked whenever the root's table reads them.
- (NSArray<NSArray<VibeBrowserRootRow *> *> *)rootSections;
// The root is about to show, such as for a check its rows depend on.
- (void)rootWillAppear:(UIViewController *)root;
// Over the root's title. None without it.
@property (nonatomic, readonly, copy, nullable) NSString *rootPrompt;

// The subfolder walk from folder, as it goes, on main after each folder it
// lists: how many folders it has listed, and how many songs they hold,
// including a few the caps may drop.
- (void)subfolderWalkFromFolder:(NSURL *)folder didListFolders:(NSUInteger)folders songs:(NSUInteger)songs;
// The walk from folder has ended, on main, before the block from
// subfoldersHandlerForFolder:fromScreen: gets its folders, or an alert
// shows. Every walk the host was asked about ends once.
- (void)subfolderWalkDidEndFromFolder:(NSURL *)folder;

// Held weakly, by a host whose state changes: its playback, its sources, or
// its root rows.
- (void)addBrowserObserver:(id<VibeBrowserHostObserver>)observer;

#pragma mark Album art

// The holder a file row's art loads into. A VibeFileMetadataHolder without it.
- (id<AudioTrackMetadataHolder>)artHolderForFileURL:(NSURL *)url;

@end

// A host that plays. The playing file's row carries the equalizer, and the
// row being opened spins. A host that is not one shows neither.
@protocol VibeBrowserPlaybackHost <VibeBrowserHost>
// Comparable paths (VibeComparablePath).
@property (nonatomic, readonly, copy, nullable) NSString *playingPath;
@property (nonatomic, readonly, copy, nullable) NSString *openingPath;
// Whether audio is coming out, and what the equalizer reads its levels from.
@property (nonatomic, readonly) BOOL audioOutputActive;
@property (nonatomic, readonly, nullable) id<EqualizerLevelSource> levelSource;
@end

NS_ASSUME_NONNULL_END
