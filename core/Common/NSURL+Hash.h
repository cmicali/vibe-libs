//
//  NSURL+Hash.h
//  vibe-libs
//

#import <Foundation/Foundation.h>

#include <sys/stat.h>

// The mark a store records for the change of the key's place
// (files/DiskCache's mayHoldEntriesFromBeforeMark:), so it stops looking under
// previous keys once none can be left.
FOUNDATION_EXPORT NSString *const _Nonnull VibeCacheKeyPlaceMark;

@interface NSData (Hash)

// Lowercase hex SHA-1: the one spelling cacheKey and the app's own hashed
// names share.
- (nonnull NSString *)sha1Hex;

// SHA-256, as raw bytes: a key for content that a crafted collision must not
// share, such as a picture's archived forms.
- (nonnull NSData *)sha256Digest;

// The bytes in lowercase hex, as sha1Hex spells its digest.
- (nonnull NSString *)lowercaseHex;

@end

@interface NSURL (Hash)

// "<size>-<mtime_us>-<sha1(place)>" from one stat and no content read. The
// place is the symlink-resolved path, said so it survives a move of the
// volume or of the app's home: "~" and the path from the home for a file
// under it, as pathKey does, or the volume's UUID, a colon, and the path
// within the volume, or the absolute path on a volume with no UUID. Changes
// with size, mtime, or place. A rewrite that preserves size and mtime keeps
// the key. nil when the stat fails; callers must then skip caching.
// TRAP: a key from before the place, which hashed the absolute path, is the
// file's previous key (previousCacheKeyForKey:). The caches look under it
// once on a miss, for as long as one can be left.
- (nullable NSString *)cacheKey;

// The same key, with the stat it was made from in *info, so a caller can
// take the file's size and date from the very version the key names. info
// may be NULL.
- (nullable NSString *)cacheKeyWithStat:(struct stat *_Nullable)info;

// The same version's key as it was before the place, which hashed the
// absolute path, with key's hash replaced: key may carry a suffix, as a cue
// window's does. nil when the two hashes are equal, as on a volume with no
// UUID, or when key is no cache key. Reads no file's content, and stats
// nothing past resolving the path's links.
- (nullable NSString *)previousCacheKeyForKey:(nonnull NSString *)key;

// The same, for a caller that has a key and no URL, as an app's move after a
// tag edit hands one. Answers for the keys this process made most recently,
// about the last thousand files, and nil for any other.
+ (nullable NSString *)previousCacheKeyForKey:(nonnull NSString *)key;

// What a memoized cacheKey is stamped with. A memo stamped below the current
// generation is stale, so its next read stats the file again. Any thread.
@property (class, readonly) uint64_t cacheKeyGeneration;

// A file was replaced under its URL by another version: a download that
// installed something other than its placeholder's size and mtime. Every
// memoized cacheKey goes stale. Any thread.
+ (void)invalidateMemoizedCacheKeys;

// A "which track is this" key (the widget's): hex SHA-1 of the comparable path
// (VibeComparablePath), relative to the app's home for a file inside it. From
// the spelling alone, so it never stats. Survives a rewrite. nil for a URL
// with no path.
//
// TRAP: the data container moves (every simulator install, possibly an iOS
// update), so a key over the absolute path would disagree with every consumer
// that captured it before the move. Hence home-relative.
- (nullable NSString *)pathKey;

@end

// What a volume lookup answers for the file at path, on the device the file's
// stat named: the volume's UUID, nil for none, and where it is mounted.
typedef void (^VibeVolumeLookup)(NSString *_Nonnull path, dev_t device, NSString *_Nullable *_Nonnull uuid,
                                 NSString *_Nullable *_Nonnull mountPath);

@interface NSURL (HashTesting)

// Replaces the volume lookup, nil for the real one, and forgets every volume
// looked up. Empty outside DEBUG.
+ (void)setVolumeLookupForTesting:(nullable VibeVolumeLookup)lookup;

@end

