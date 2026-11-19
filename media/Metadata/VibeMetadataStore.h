//
//  VibeMetadataStore.h
//  vibe-libs
//
//  The metadata cache's storage: one VibeCacheStore under the cache's root.
//  Each file's tags are an entry keyed by its cacheKey, and each entry names
//  its picture by the SHA-256 of the picture's bytes. A picture is a shared
//  item with two parts, the row thumbnail and the display-art rendition, so
//  files that embed one picture keep one copy. It deals in bytes: the loader
//  archives and decodes the tags.
//
//  It imports the stores of Vibe's releases before it, then removes them
//  (VibeMetadataImport.h).
//

#import <Foundation/Foundation.h>
#import "VibeCacheStore.h"
#import "AudioTrackMetadataCache.h"

NS_ASSUME_NONNULL_BEGIN

// The tags' archive format. Bump it whenever the archived fields, the
// rendition, or their meaning change. An older row then misses for a read
// that may open its file, and answers, marked older, for one that may not.
// 11 is the PINCache store's last version, "Audio Track Metadata v11".
FOUNDATION_EXPORT const NSInteger VibeMetadataTagsFormat;
// The picture's parts' format.
FOUNDATION_EXPORT const NSInteger VibeMetadataArtFormat;
// The store's directory under the root.
FOUNDATION_EXPORT NSString *const VibeMetadataStoreName;

// The tags' archive, PINDiskCache's own: an insecure keyed archive, so the
// import copies the old store's bytes as they are.
FOUNDATION_EXPORT NSData *_Nullable VibeMetadataArchive(id<NSCoding> tags);
// The archive's root object, only when it is of tagsClass. Never throws.
FOUNDATION_EXPORT id _Nullable VibeMetadataUnarchive(NSData *archive, Class tagsClass);

@interface VibeMetadataStore : NSObject

// The store under rootPath, nil for the user's caches, shared by every
// caller in the process that checks it out, and closed when the last checks
// it in. TRAP: a store opens once a process (CH21), and Vibe's iOS app keeps
// two metadata caches over one root. Opens the database on the caller's
// thread, so call it off main.
+ (VibeMetadataStore *)checkOutStoreUnderRootPath:(nullable NSString *)rootPath;
- (void)checkIn;
- (instancetype)init NS_UNAVAILABLE;

// Nil when the database would not open, as when another process holds it.
// Every read then misses and every write is dropped.
@property (nonatomic, readonly, nullable) VibeCacheStore *cacheStore;

// MARK: Entries

// The tags' archive under key, the row's format, and its picture's name. An
// older row answers only when acceptingOlder, and the hit says so. A row a
// tag edit left with the art alone never answers. During an import, a miss
// looks in the old stores first, and imports what it finds.
- (nullable VibeCacheHit *)tagsHitForKey:(NSString *)key acceptingOlder:(BOOL)acceptingOlder;

// Files the tags' archive under key, naming the picture, in one transaction.
// A part the picture already has is not written again. With no name, the
// picture is named by the digest of the rendition, or of the thumbnail with
// none, as the import names it: a rendition is the picture's bytes, or a
// fixed downscale of them. Returns the name the entry names, or nil.
- (nullable NSString *)fileTags:(id<NSCoding>)tags
                      thumbnail:(nullable NSData *)thumbnail
                      rendition:(nullable NSData *)rendition
                    pictureName:(nullable NSString *)pictureName
                         forKey:(NSString *)key;
// The same, for an archive made already, as the import's are.
- (nullable NSString *)fileArchive:(NSData *)archive
                         thumbnail:(nullable NSData *)thumbnail
                         rendition:(nullable NSData *)rendition
                       pictureName:(nullable NSString *)pictureName
                            forKey:(NSString *)key;

// The entry under key. Its picture goes too, unless another entry names it.
- (void)removeEntryForKey:(NSString *)key;

// After a tag-only rewrite (AudioTrackMetadataCache.h). The entry moves to
// newKey with its tags dropped, so the next read parses them, and it names
// the same picture unless artChanged. An entry newKey already holds is kept.
- (void)moveEntryOfRetaggedFileFromKey:(NSString *)oldKey
                                 toKey:(NSString *)newKey
                            artChanged:(BOOL)artChanged;

// MARK: Pictures

- (nullable NSData *)thumbnailOfPicture:(NSString *)name;
- (nullable NSData *)renditionOfPicture:(NSString *)name;
// A picture's name: the lowercase hex of the SHA-256 of its bytes.
+ (NSString *)nameOfPictureWithDigest:(NSData *)digest;

// MARK: The whole store

// Sets one budget. The tags and the thumbnails share one limit, their sum,
// and the renditions have their own, so art never pushes out an entry. Every
// row ages by the longest age limit. 0 is none, so a tags or thumbnails
// budget of 0 lifts their shared limit.
- (void)setByteLimit:(unsigned long long)byteLimit
            ageLimit:(NSTimeInterval)ageLimit
           forBudget:(VibeMetadataCacheStore)budget;

- (VibeCacheUsage)usage;

// Every entry and picture, and the old stores an import has not reached.
// Blocks until the store is empty.
- (void)removeAll;

// The part names, for tests that stand in for a trim.
@property (class, nonatomic, readonly) NSString *thumbnailPart;
@property (class, nonatomic, readonly) NSString *renditionPart;
// Test seam, empty outside DEBUG: runs block once the import has ended, or
// at once with none.
- (void)performAfterImportForTesting:(dispatch_block_t)block;

@end

NS_ASSUME_NONNULL_END
