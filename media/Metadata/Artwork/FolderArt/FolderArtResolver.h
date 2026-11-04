//
// FolderArtResolver.h
// vibe-libs
//
// The cover beside an audio file with absent or undecodable art, consulted by
// AudioTrackArtwork. Per directory, lazy, never on the scan's path and never
// persisted; the cost rules are this piece's AGENTS.md, Folder art.
//

#import <Foundation/Foundation.h>
#import "PlatformTypes.h"

NS_ASSUME_NONNULL_BEGIN

// Posted on main when a folder's question is answered, "it has none"
// included. A view may hold the previous track's art until the answer.
extern NSNotificationName const FolderArtDidResolveNotification;

// Posted on main, under holdsCloudCovers, when a folder's cover is a cloud
// placeholder, so its read would download it. The resolver reads none, and
// waits: an app that wants it downloads it, then calls
// artDidArriveInDirectories:. The user info's FolderArtPathKey is the
// cover's path, and FolderArtDirectoryKey its folder.
extern NSNotificationName const FolderArtInCloudNotification;
extern NSString *const FolderArtPathKey;
extern NSString *const FolderArtDirectoryKey;

// Whether folder art is on, and whether a directory may be read without
// raising a permission panel. An app answers both (setEnabledProvider:).
typedef BOOL (^FolderArtEnabledProvider)(void);
typedef BOOL (^FolderArtAccessProvider)(NSString *directory);

@interface FolderArtResolver : NSObject

+ (instancetype)sharedInstance;

// The two answers the resolver takes from an app, usually at launch. Until
// an app installs them, folder art is off and any directory may be read.
// Installing re-reads the enabled answer and drops cached images, as
// folderArtSettingDidChange does.
// Any thread.
- (void)setEnabledProvider:(FolderArtEnabledProvider)enabledProvider
             accessProvider:(FolderArtAccessProvider)accessProvider;

// The row thumbnail, or nil. Never blocks or touches the filesystem, O(1)
// under the lock, so safe while drawing; an unknown folder schedules a
// background resolve. Any thread.
- (nullable VibeImage *)cachedThumbnailForAudioFilePath:(nullable NSString *)path;

// The full cover if decoded now; non-blocking.
- (nullable VibeImage *)cachedDisplayImageForAudioFilePath:(nullable NSString *)path;

// Resolves, reads and decodes as needed. Blocking: background only.
- (nullable VibeImage *)displayImageForAudioFilePath:(nullable NSString *)path;

// YES while the folder is unresolved or its cover undecoded; NO for good once
// it has none, so artNeedsLoad cannot spin. A pure read, on main.
- (BOOL)needsBackgroundLoadForAudioFilePath:(nullable NSString *)path;

// A walk's harvest: every directory visited and the cover in each that has
// one, settled with no I/O of ours. Recorded even with the setting off.
- (void)noteListedDirectories:(nullable NSSet<NSString *> *)directories
       artFilenameByDirectory:(nullable NSDictionary<NSString *, NSString *> *)artFilenameByDirectory;

// Folders from a multi-file open: resolve each, lazily, by one listing rather
// than stat probes.
- (void)preferListingForDirectories:(nullable NSSet<NSString *> *)directories;

// Every writer of the setting must reach this: the value is cached here.
// Drops decoded covers and keeps every settled answer, since the setting
// governs whether the fallback is consulted, not what a folder holds.
- (void)folderArtSettingDidChange;

// Forgets no-grant answers and re-arms read-blocked covers, which keep their
// path. Never a full wipe: an open's grant lands just after its walk.
- (void)invalidateDirectoriesSettledWithoutGrant;

// Off by default: a read of a cover in the cloud downloads it, as any read
// does. On, the resolver reads none: it posts FolderArtInCloudNotification
// once, holds the folder's reads, and waits for the app. An app that turns
// it on downloads covers under its own rules. Set it before the first read.
@property (nonatomic) BOOL holdsCloudCovers;

// The folder's cover, when its read found it in the cloud, or nil. A pure
// read, on any thread.
- (nullable NSString *)cloudArtPathForAudioFilePath:(nullable NSString *)path;

// The covers of these folders may be on the device now: each in the cloud
// is read again at once, and its pixels post FolderArtDidResolveNotification.
// A cover still in the cloud posts FolderArtInCloudNotification again, so an
// app caps its own retries. Any thread.
- (void)artDidArriveInDirectories:(NSSet<NSString *> *)directories;

@end

NS_ASSUME_NONNULL_END
