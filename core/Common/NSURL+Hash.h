//
//  NSURL+Hash.h
//  vibe-libs
//

#import <Foundation/Foundation.h>

#include <sys/stat.h>

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
// place is the resolved path said so a move of the volume or the home keeps
// it: "~/" and the path from the home, or "<volume UUID>:" and the path within
// the volume, or the absolute path on a volume with no UUID. nil when the stat
// fails; callers must then skip caching. A key from before the place is the
// file's previous key (previousCacheKeyForKey:).
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
