//
//  VibeCacheStore.h
//  vibe-libs
//
//  A bounded disk cache over SQLite. Each entry is a row keyed by the caller's
//  key, with a blob, the number of the blob's format, the name of a shared
//  item it points into, and its last use. A small blob lives in its row. A
//  large one lives in a file beside the database, which the row lists with its
//  size, so a count or a trim reads rows and never the folder.
//
//  Shared items are a second table, keyed by a name and a part, that entries
//  point into by name, as a file's entry names its picture. A shared item goes
//  when no entry names it, or when a trim takes it.
//
//  TRAP: one process opens a store, and one store object at a time. A second
//  open of the same directory fails until the first closes.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// What a read found.
@interface VibeCacheHit : NSObject
@property (nonatomic, readonly) NSData *data;
// The format the row was written in. It is never newer than the format asked.
@property (nonatomic, readonly) NSInteger format;
// The row's format is older than the one asked, so the fields that format
// lacks are unknown.
@property (nonatomic, readonly, getter=isOlder) BOOL older;
// The shared item an entry names, or nil. Always nil for a shared item.
@property (nonatomic, readonly, nullable) NSString *sharedName;
@end

// Rows and bytes. The bytes are the blobs' and the files' sizes, summed.
typedef struct {
    NSUInteger entries;
    NSUInteger sharedItems;
    unsigned long long bytes;
} VibeCacheUsage;

@interface VibeCacheStore : NSObject

// 1 GiB, the default byte limit.
@property (class, nonatomic, readonly) unsigned long long defaultByteLimit;
// 180 days, the default age limit.
@property (class, nonatomic, readonly) NSTimeInterval defaultAgeLimit;

// The store in a directory named `name` under rootPath, nil for the user's
// caches. Nil when the directory can't be made, or another open holds it.
+ (nullable instancetype)storeWithName:(NSString *)name rootPath:(nullable NSString *)rootPath;

// The store in `directory`, made if missing. A database that will not open is
// removed with its files and made again.
- (nullable instancetype)initWithDirectory:(NSString *)directory NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) NSString *directory;

// The limits the creator sets. 0 means none. A trim cuts to 90% of the byte
// limit, least recently used first. The age counts from an entry's last use,
// which a read records once a day at most.
@property (atomic) unsigned long long byteLimit;
@property (atomic) NSTimeInterval ageLimit;
// A blob longer than this goes to a file. 64 KiB by default.
@property (atomic) NSUInteger inlineLimit;

// MARK: Entries

// The entry under key, only in `format`. An older or a newer row is a miss.
- (nullable VibeCacheHit *)hitForKey:(NSString *)key format:(NSInteger)format;
// The entry under key in `format` or an older one, which the hit marks. A
// newer row is a miss.
- (nullable VibeCacheHit *)hitForKey:(NSString *)key acceptingFormatsUpTo:(NSInteger)format;
- (BOOL)hasEntryForKey:(NSString *)key;

// Writes or replaces the entry, and returns once it reads back. A write that
// fails leaves no entry under key, so it reads as a miss.
- (void)setData:(NSData *)data forKey:(NSString *)key format:(NSInteger)format sharedName:(nullable NSString *)sharedName;
- (void)removeEntryForKey:(NSString *)key;
// Moves the entry to newKey, replacing any there. NO when oldKey has none.
- (BOOL)moveEntryFromKey:(NSString *)oldKey toKey:(NSString *)newKey;

// MARK: Shared items

- (nullable VibeCacheHit *)sharedHitForName:(NSString *)name part:(NSString *)part format:(NSInteger)format;
- (nullable VibeCacheHit *)sharedHitForName:(NSString *)name part:(NSString *)part acceptingFormatsUpTo:(NSInteger)format;
- (BOOL)hasSharedItemForName:(NSString *)name part:(NSString *)part;
- (void)setSharedData:(NSData *)data forName:(NSString *)name part:(NSString *)part format:(NSInteger)format;

// MARK: The whole store

// A sum the database keeps as it changes, so it reads one row. It never waits
// for a write.
- (VibeCacheUsage)usage;
// The same, with the completion on the main thread.
- (void)usageWithCompletion:(void (^)(VibeCacheUsage usage))completion;

// Removes every entry, every shared item, and their files. The completion
// runs on the store's queue.
- (void)removeAllWithCompletion:(nullable dispatch_block_t)completion;

// The daily work, run now: the age limit, the shared items no entry names,
// and the byte limit. A store runs it on its own once a day.
- (void)performMaintenanceWithCompletion:(nullable dispatch_block_t)completion;

// Runs the block on the store's queue after the work queued before it.
- (void)performAfterQueuedWork:(dispatch_block_t)block;

// Waits for queued work, then closes the database and frees the directory. A
// closed store reads as empty and ignores writes. Dealloc closes it too.
- (void)close;

@end

NS_ASSUME_NONNULL_END
