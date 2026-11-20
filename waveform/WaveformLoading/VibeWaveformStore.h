//
//  VibeWaveformStore.h
//  vibe-libs
//
//  The waveform cache's entries: a VibeCacheStore that lists each waveform's
//  file with its size, its format, and its last use (files/DiskCache). The
//  first open brings the entries of the PINCache store before it over, by a
//  rename of each file, and a miss looks there until the import is done.
//
//  One per folder in a process, since a folder's store opens once: every
//  cache under one root shares it. Every method may be called from any
//  thread, and none waits on the cache's queues.
//

#import <Foundation/Foundation.h>
#import "VibeCacheStore.h"

NS_ASSUME_NONNULL_BEGIN

@interface VibeWaveformStore : NSObject

// The store's directory name under the root: the waveform cache's cacheName.
@property (class, nonatomic, readonly) NSString *name;
// The PINCache store this one replaces, whose entries the import brings over.
@property (class, nonatomic, readonly) NSString *legacyName;

// The store under rootPath, nil for the user's caches, opened and shared by
// every caller under that root. Its import starts in the background if the
// old store is there. It blocks for the open, a few ms, so call it off main.
+ (instancetype)storeUnderRoot:(nullable NSString *)rootPath;

- (instancetype)init NS_UNAVAILABLE;

// Nil when the folder could not be opened. Then every read misses and every
// write is dropped, as a cache may. A caller goes through the methods below,
// which reach the old store during the import. The tests read it directly.
@property (nonatomic, readonly, nullable) VibeCacheStore *entries;

// The archive filed under key in the current format, from the old store
// during the import, which then lists it here. Nil on a miss.
- (nullable NSData *)dataForKey:(NSString *)key;
// The same, and a miss looks once under the previous key of url's file, its
// window kept (NSURL+Hash, CH33), while an entry may be filed under one:
// during the import, and until such an entry would have aged out (CH34). The
// entry found there, or in the old store, moves to key and answers.
- (nullable NSData *)dataForKey:(NSString *)key url:(nullable NSURL *)url;
- (void)setData:(NSData *)data forKey:(NSString *)key;
- (BOOL)hasEntryForKey:(NSString *)key;
- (void)removeEntryForKey:(NSString *)key;
// Moves the entry, from the old store during the import, or from oldKey's
// previous key, which this process knows when it made oldKey lately. NO when
// there is none, or newKey already holds one, which is kept.
- (BOOL)moveEntryFromKey:(NSString *)oldKey toKey:(NSString *)newKey;

// The limits, over files/DiskCache's defaults.
- (void)setByteLimit:(unsigned long long)byteLimit ageLimit:(NSTimeInterval)ageLimit;
// The entries and bytes the store lists. During the import, the entries not
// yet brought over are not counted.
- (VibeCacheUsage)usage;

// Ends the import, removes the old store, and empties this one. It returns
// once the store is empty.
- (void)removeAll;

// YES while the import runs, or waits to run again at the next open.
@property (nonatomic, readonly, getter=isImporting) BOOL importing;

// For the tests: while held, an import waits before each file, and a store
// that loses its last user stops its import there, as a quit would. Empty
// outside DEBUG.
+ (void)holdImportsForTesting:(BOOL)held;

@end

NS_ASSUME_NONNULL_END
