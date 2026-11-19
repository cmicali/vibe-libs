//  PINCache is a modified version of TMCache
//  Modifications by Garrett Moon
//  Copyright (c) 2015 Pinterest. All rights reserved.

#import "PINDiskCache.h"

#if __IPHONE_OS_VERSION_MIN_REQUIRED >= __IPHONE_4_0
#import <UIKit/UIKit.h>
#endif

#import <fcntl.h>
#import <stdio.h> // Vibe: renamex_np
#import <pthread.h>
#import <sys/stat.h>
#import <sys/xattr.h>
#import <unistd.h>

#import <PINOperation/PINOperation.h>

#define PINDiskCacheError(error) if (error) { NSLog(@"%@ (%d) ERROR: %@", \
[[NSString stringWithUTF8String:__FILE__] lastPathComponent], \
__LINE__, [error localizedDescription]); }

#define PINDiskCacheException(exception) if (exception) { NSAssert(NO, [exception reason]); }

const char * PINDiskCacheAgeLimitAttributeName = "com.pinterest.PINDiskCache.ageLimit";
const char * PINDiskCacheAccessCountAttributeName = "com.pinterest.PINDiskCache.accessCount";
NSString * const PINDiskCacheErrorDomain = @"com.pinterest.PINDiskCache";
NSErrorUserInfoKey const PINDiskCacheErrorReadFailureCodeKey = @"PINDiskCacheErrorReadFailureCodeKey";
NSErrorUserInfoKey const PINDiskCacheErrorWriteFailureCodeKey = @"PINDiskCacheErrorWriteFailureCodeKey";
NSString * const PINDiskCachePrefix = @"com.pinterest.PINDiskCache";
static NSString * const PINDiskCacheSharedName = @"PINDiskCacheShared";

NSUInteger PINDiskCacheDefaultByteLimit = 50 * 1024 * 1024; // 50 MB by default
NSTimeInterval PINDiskCacheDefaultAgeLimit = 60 * 60 * 24 * 30; // 30 days by default

static NSString * const PINDiskCacheOperationIdentifierTrimToDate = @"PINDiskCacheOperationIdentifierTrimToDate";
static NSString * const PINDiskCacheOperationIdentifierTrimToSize = @"PINDiskCacheOperationIdentifierTrimToSize";
static NSString * const PINDiskCacheOperationIdentifierTrimToSizeByDate = @"PINDiskCacheOperationIdentifierTrimToSizeByDate";

typedef NS_ENUM(NSUInteger, PINDiskCacheCondition) {
    PINDiskCacheConditionNotReady = 0,
    PINDiskCacheConditionReady = 1,
};

static PINOperationDataCoalescingBlock PINDiskTrimmingSizeCoalescingBlock = ^id(NSNumber *existingSize, NSNumber *newSize) {
    NSComparisonResult result = [existingSize compare:newSize];
    return (result == NSOrderedDescending) ? newSize : existingSize;
};

static PINOperationDataCoalescingBlock PINDiskTrimmingDateCoalescingBlock = ^id(NSDate *existingDate, NSDate *newDate) {
    NSComparisonResult result = [existingDate compare:newDate];
    return (result == NSOrderedDescending) ? newDate : existingDate;
};

// Vibe: a record's dates and size are nil when its file's attributes could
// not be read. [NSNumber compare:nil] raises, and [NSDate compare:nil] calls
// nil equal to everything, so the trims sort with total orders: a nil date is
// oldest and a nil size largest. Unknown entries go first. From upstream's
// 0073330.
static NSComparisonResult PINDiskCacheCompareDates(NSDate * _Nullable date1, NSDate * _Nullable date2)
{
    if (date1 == nil || date2 == nil) {
        return date1 == date2 ? NSOrderedSame : (date1 == nil ? NSOrderedAscending : NSOrderedDescending);
    }
    return [date1 compare:date2];
}

static NSComparisonResult PINDiskCacheCompareSizes(NSNumber * _Nullable size1, NSNumber * _Nullable size2)
{
    if (size1 == nil || size2 == nil) {
        return size1 == size2 ? NSOrderedSame : (size1 == nil ? NSOrderedDescending : NSOrderedAscending);
    }
    return [size1 compare:size2];
}

const char * PINDiskCacheFileSystemRepresentation(NSURL *url)
{
    return url.fileSystemRepresentation;
}

// Vibe: a hit re-dates its file, one utimes per read, only once the recorded
// date is a day old: least-recently-used eviction needs no finer clock. The
// recorded date is left alone too, so it stays the file's and a relaunch ranks
// the entries as this run did.
static BOOL PINDiskCacheShouldTouch(NSDate *lastModifiedDate, NSDate *now)
{
    return !lastModifiedDate || [now timeIntervalSinceDate:lastModifiedDate] >= 24 * 60 * 60;
}

// Vibe: a file's date as Foundation reads it, so the two compare.
static NSDate *PINDiskCacheDateOfTimespec(struct timespec time)
{
    return [NSDate dateWithTimeIntervalSinceReferenceDate:((double)time.tv_sec - NSTimeIntervalSince1970) + 1.0e-9 * (double)time.tv_nsec];
}

// Vibe: a file's bytes and its creation and last modified dates, from one
// open. nil when the file is gone or can't be read whole.
static NSData *PINDiskCacheReadFile(NSURL *fileURL, NSDate **outCreatedDate, NSDate **outModifiedDate)
{
    const char *path = PINDiskCacheFileSystemRepresentation(fileURL);
    int fd = path ? open(path, O_RDONLY | O_CLOEXEC) : -1;
    if (fd < 0) {
        return nil;
    }
    NSData *data = nil;
    struct stat info;
    if (fstat(fd, &info) == 0 && info.st_size >= 0) {
        size_t length = (size_t)info.st_size;
        char *bytes = malloc(length > 0 ? length : 1);
        size_t done = 0;
        while (bytes && done < length) {
            ssize_t got = read(fd, bytes + done, length - done);
            if (got < 0 && errno == EINTR) {
                continue;
            }
            if (got <= 0) {
                break;
            }
            done += (size_t)got;
        }
        if (bytes && done == length) {
            data = [NSData dataWithBytesNoCopy:bytes length:length freeWhenDone:YES];
            *outCreatedDate = PINDiskCacheDateOfTimespec(info.st_birthtimespec);
            *outModifiedDate = PINDiskCacheDateOfTimespec(info.st_mtimespec);
        } else {
            free(bytes);
        }
    }
    close(fd);
    return data;
}

// Vibe: whether two dates of one file are the same, within the rounding of
// the two ways a date is read.
static BOOL PINDiskCacheSameFileDate(NSDate *date, NSDate *other)
{
    return date && other && fabs([date timeIntervalSinceDate:other]) < 1e-6;
}

VibePINDiskCacheCountSeam VibePINDiskCacheCountSeamFunction = NULL; // Vibe: a test seam

static void PINDiskCacheCallCountSeam(PINDiskCache *cache, VibePINDiskCacheCountStage stage, NSString *key)
{
    VibePINDiskCacheCountSeam seam = __atomic_load_n(&VibePINDiskCacheCountSeamFunction, __ATOMIC_ACQUIRE);
    if (seam) {
        seam(cache, stage, key);
    }
}

// Vibe: the files a cache that keeps no records has accounted for while its
// launch's count runs: each the count added, and each a write, a removal, or
// a move settled first. So a change goes on during the count, and the count
// skips each file it settled. A set of 64-bit hashes of file names, open
// addressed and kept at most half full: 4 MB of slots up to 262,144 files,
// which a full store of 4 KB files reaches, then 8 MB, and for a moment while
// it grows both. A set of the names would hold about 25 MB. TRAP: two names
// whose hashes collide, under once in 10^8 launches at 262,144 files, leave
// one file's bytes uncounted until a launch.
typedef struct {
    uint64_t *slots; // 0 is an empty slot
    size_t capacity; // a power of two, or 0
    size_t count;
    BOOL counting; // the launch's count runs
    BOOL full; // a hash could not be stored, so changes wait for the count
} PINDiskCacheFileSet;

typedef NS_ENUM(NSInteger, PINDiskCacheFileSetResult) {
    PINDiskCacheFileSetAdded,
    PINDiskCacheFileSetPresent,
    PINDiskCacheFileSetUnstored, // the set could not grow
};

static uint64_t PINDiskCacheFileNameHash(NSString *fileName)
{
    uint64_t hash = 14695981039346656037ULL; // FNV-1a
    for (const char *byte = fileName.UTF8String; byte && *byte; byte++) {
        hash = (hash ^ (uint8_t)*byte) * 1099511628211ULL;
    }
    return hash ?: 1;
}

static size_t PINDiskCacheFileSetSlot(uint64_t hash, size_t capacity)
{
    hash ^= hash >> 33;
    hash *= 0xff51afd7ed558ccdULL;
    hash ^= hash >> 33;
    return (size_t)hash & (capacity - 1);
}

static void PINDiskCacheFileSetPlace(uint64_t *slots, size_t capacity, uint64_t hash)
{
    size_t slot = PINDiskCacheFileSetSlot(hash, capacity);
    while (slots[slot] != 0) {
        slot = (slot + 1) & (capacity - 1);
    }
    slots[slot] = hash;
}

// Adds the file's hash. A set that could not grow marks itself full, and
// stores nothing more, so the cache's changes wait for the count from then on.
static PINDiskCacheFileSetResult PINDiskCacheFileSetAdd(PINDiskCacheFileSet *set, uint64_t hash)
{
    if (set->capacity) {
        for (size_t slot = PINDiskCacheFileSetSlot(hash, set->capacity); set->slots[slot] != 0;
             slot = (slot + 1) & (set->capacity - 1)) {
            if (set->slots[slot] == hash) {
                return PINDiskCacheFileSetPresent;
            }
        }
    }
    if (set->full) {
        return PINDiskCacheFileSetUnstored;
    }
    if ((set->count + 1) * 2 > set->capacity) {
        size_t capacity = set->capacity ? set->capacity * 2 : 1024;
        uint64_t *slots = calloc(capacity, sizeof(uint64_t));
        if (!slots) {
            set->full = YES;
            return PINDiskCacheFileSetUnstored;
        }
        for (size_t slot = 0; slot < set->capacity; slot++) {
            if (set->slots[slot] != 0) {
                PINDiskCacheFileSetPlace(slots, capacity, set->slots[slot]);
            }
        }
        free(set->slots);
        set->slots = slots;
        set->capacity = capacity;
    }
    PINDiskCacheFileSetPlace(set->slots, set->capacity, hash);
    set->count++;
    return PINDiskCacheFileSetAdded;
}

// The count is done, or every entry was removed during it.
static void PINDiskCacheFileSetEnd(PINDiskCacheFileSet *set)
{
    free(set->slots);
    *set = (PINDiskCacheFileSet){0};
}

// Vibe: an automatic trim cuts to 90% of the limit, not to just under it, so
// a full cache sorts every entry once per tenth of its size written rather
// than on every write.
static NSUInteger PINDiskCacheTrimTarget(NSUInteger byteLimit)
{
    return byteLimit - byteLimit / 10;
}

@interface PINDiskCacheMetadata : NSObject
// When the object was added to the disk cache
@property (nonatomic, strong) NSDate *createdDate;
// Last time the object was accessed
@property (nonatomic, strong) NSDate *lastModifiedDate;
@property (nonatomic, strong) NSNumber *size;
// Age limit is used in conjuction with ttl
@property (nonatomic) NSTimeInterval ageLimit;
// Access count is how many times this object has been fetched. Used with the LFU
@property (nonatomic) NSInteger accessCount;
@end

@interface PINDiskCache () {
    PINDiskCacheSerializerBlock _serializer;
    PINDiskCacheDeserializerBlock _deserializer;
    
    PINDiskCacheKeyEncoderBlock _keyEncoder;
    PINDiskCacheKeyDecoderBlock _keyDecoder;

    // Vibe: the files accounted for while the launch's count runs, under the
    // lock. Held by value, so making it cannot fail.
    PINDiskCacheFileSet _countedFiles;
}

@property (assign, nonatomic) pthread_mutex_t mutex;
@property (copy, nonatomic) NSString *name;
@property (assign) NSUInteger byteCount;
@property (strong, nonatomic) NSURL *cacheURL;
@property (strong, nonatomic) PINOperationQueue *operationQueue;
@property (strong, nonatomic) NSMutableDictionary <NSString *, PINDiskCacheMetadata *> *metadata;
@property (assign, nonatomic) pthread_cond_t diskWritableCondition;
@property (assign, nonatomic) BOOL diskWritable;
@property (assign, nonatomic) pthread_cond_t diskStateKnownCondition;
@property (assign, nonatomic) BOOL diskStateKnown;
@property (assign, nonatomic) BOOL writingProtectionOptionSet;
// Vibe: for a cache that keeps no records, a date no entry was last used
// before, in seconds since the reference date: the launch's count lowers it,
// as the records the mode drops do. A write's entry is newer, and a hit only
// moves an entry's date later. The age limit's trim lists nothing while it is
// not past.
@property (assign, nonatomic) NSTimeInterval oldestUse;
@end

@implementation PINDiskCache

static NSURL *_sharedTrashURL;

@synthesize willAddObjectBlock = _willAddObjectBlock;
@synthesize willRemoveObjectBlock = _willRemoveObjectBlock;
@synthesize willRemoveAllObjectsBlock = _willRemoveAllObjectsBlock;
@synthesize didAddObjectBlock = _didAddObjectBlock;
@synthesize didRemoveObjectBlock = _didRemoveObjectBlock;
@synthesize didRemoveAllObjectsBlock = _didRemoveAllObjectsBlock;
@synthesize byteLimit = _byteLimit;
@synthesize ageLimit = _ageLimit;
@synthesize ttlCache = _ttlCache;
@synthesize recordsOnDemand = _recordsOnDemand; // Vibe: records on demand

// Vibe: whether the cache keeps no records, read with no lock. The mode is
// one way, and a read that sees it still off takes the lock and asks again.
static BOOL PINDiskCacheKeepsNoRecords(PINDiskCache *cache)
{
    return __atomic_load_n(&cache->_recordsOnDemand, __ATOMIC_ACQUIRE);
}

#if TARGET_OS_IPHONE
@synthesize writingProtectionOption = _writingProtectionOption;
@synthesize writingProtectionOptionSet = _writingProtectionOptionSet;
#endif

#pragma mark - Initialization -

- (void)dealloc
{
    __unused int result = pthread_mutex_destroy(&_mutex);
    NSCAssert(result == 0, @"Failed to destroy lock in PINDiskCache %p. Code: %d", (void *)self, result);
    pthread_cond_destroy(&_diskWritableCondition);
    pthread_cond_destroy(&_diskStateKnownCondition);
    free(_countedFiles.slots); // Vibe
}

- (instancetype)init
{
    @throw [NSException exceptionWithName:@"Must initialize with a name" reason:@"PINDiskCache must be initialized with a name. Call initWithName: instead." userInfo:nil];
    return [self initWithName:@""];
}

- (instancetype)initWithName:(NSString *)name
{
    return [self initWithName:name rootPath:[NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) objectAtIndex:0]];
}

- (instancetype)initWithName:(NSString *)name rootPath:(NSString *)rootPath
{
    return [self initWithName:name rootPath:rootPath serializer:nil deserializer:nil];
}

- (instancetype)initWithName:(NSString *)name rootPath:(NSString *)rootPath serializer:(PINDiskCacheSerializerBlock)serializer deserializer:(PINDiskCacheDeserializerBlock)deserializer
{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [self initWithName:name rootPath:rootPath serializer:serializer deserializer:deserializer operationQueue:[PINOperationQueue sharedOperationQueue]];
#pragma clang diagnostic pop
}

- (instancetype)initWithName:(NSString *)name
                    rootPath:(NSString *)rootPath
                  serializer:(PINDiskCacheSerializerBlock)serializer
                deserializer:(PINDiskCacheDeserializerBlock)deserializer
              operationQueue:(PINOperationQueue *)operationQueue
{
  return [self initWithName:name
                     prefix:PINDiskCachePrefix
                   rootPath:rootPath
                 serializer:serializer
               deserializer:deserializer
                 keyEncoder:nil
                 keyDecoder:nil
             operationQueue:operationQueue];
}

- (instancetype)initWithName:(NSString *)name
                      prefix:(NSString *)prefix
                    rootPath:(NSString *)rootPath
                  serializer:(PINDiskCacheSerializerBlock)serializer
                deserializer:(PINDiskCacheDeserializerBlock)deserializer
                  keyEncoder:(PINDiskCacheKeyEncoderBlock)keyEncoder
                  keyDecoder:(PINDiskCacheKeyDecoderBlock)keyDecoder
              operationQueue:(PINOperationQueue *)operationQueue
{
    return [self initWithName:name prefix:prefix
                     rootPath:rootPath
                   serializer:serializer
                 deserializer:deserializer
                   keyEncoder:keyEncoder
                   keyDecoder:keyDecoder
               operationQueue:operationQueue
                     ttlCache:NO];
}

- (instancetype)initWithName:(NSString *)name
                      prefix:(NSString *)prefix
                    rootPath:(NSString *)rootPath
                  serializer:(PINDiskCacheSerializerBlock)serializer
                deserializer:(PINDiskCacheDeserializerBlock)deserializer
                  keyEncoder:(PINDiskCacheKeyEncoderBlock)keyEncoder
                  keyDecoder:(PINDiskCacheKeyDecoderBlock)keyDecoder
              operationQueue:(PINOperationQueue *)operationQueue
                    ttlCache:(BOOL)ttlCache
{
    return [self initWithName:name prefix:prefix
                     rootPath:rootPath
                   serializer:serializer
                 deserializer:deserializer
                   keyEncoder:keyEncoder
                   keyDecoder:keyDecoder
               operationQueue:operationQueue
                     ttlCache:ttlCache
                    byteLimit:PINDiskCacheDefaultByteLimit
                     ageLimit:PINDiskCacheDefaultAgeLimit];
}

- (instancetype)initWithName:(nonnull NSString *)name
                      prefix:(nonnull NSString *)prefix
                    rootPath:(nonnull NSString *)rootPath
                  serializer:(nullable PINDiskCacheSerializerBlock)serializer
                deserializer:(nullable PINDiskCacheDeserializerBlock)deserializer
                  keyEncoder:(nullable PINDiskCacheKeyEncoderBlock)keyEncoder
                  keyDecoder:(nullable PINDiskCacheKeyDecoderBlock)keyDecoder
              operationQueue:(nonnull PINOperationQueue *)operationQueue
                    ttlCache:(BOOL)ttlCache
                   byteLimit:(NSUInteger)byteLimit
                    ageLimit:(NSTimeInterval)ageLimit
{
    return [self initWithName:name 
                       prefix:prefix
                     rootPath:rootPath
                   serializer:serializer
                 deserializer:deserializer
                   keyEncoder:keyEncoder
                   keyDecoder:keyDecoder
               operationQueue:operationQueue
                     ttlCache:ttlCache
                    byteLimit:byteLimit
                     ageLimit:ageLimit
             evictionStrategy:PINCacheEvictionStrategyLeastRecentlyUsed];

}

- (instancetype)initWithName:(NSString *)name
                      prefix:(NSString *)prefix
                    rootPath:(NSString *)rootPath
                  serializer:(PINDiskCacheSerializerBlock)serializer
                deserializer:(PINDiskCacheDeserializerBlock)deserializer
                  keyEncoder:(PINDiskCacheKeyEncoderBlock)keyEncoder
                  keyDecoder:(PINDiskCacheKeyDecoderBlock)keyDecoder
              operationQueue:(PINOperationQueue *)operationQueue
                    ttlCache:(BOOL)ttlCache
                   byteLimit:(NSUInteger)byteLimit
                    ageLimit:(NSTimeInterval)ageLimit
            evictionStrategy:(PINCacheEvictionStrategy)evictionStrategy
{
    if (!name) {
        return nil;
    }

    NSAssert(((!serializer && !deserializer) || (serializer && deserializer)),
             @"PINDiskCache must be initialized with a serializer AND deserializer.");
    
    NSAssert(((!keyEncoder && !keyDecoder) || (keyEncoder && keyDecoder)),
              @"PINDiskCache must be initialized with an encoder AND decoder.");
    
    if (self = [super init]) {
        __unused int result = pthread_mutex_init(&_mutex, NULL);
        NSAssert(result == 0, @"Failed to init lock in PINDiskCache %@. Code: %d", self, result);
        
        _name = [name copy];
        _prefix = [prefix copy];
        _operationQueue = operationQueue;
        _ttlCache = ttlCache;
        _willAddObjectBlock = nil;
        _willRemoveObjectBlock = nil;
        _willRemoveAllObjectsBlock = nil;
        _didAddObjectBlock = nil;
        _didRemoveObjectBlock = nil;
        _didRemoveAllObjectsBlock = nil;
        
        _byteCount = 0;
        _byteLimit = byteLimit;
        _ageLimit = ageLimit;
        _evictionStrategy = evictionStrategy;
        
#if TARGET_OS_IPHONE
        _writingProtectionOptionSet = NO;
        // This is currently the default for files, but we'd rather not write it if it's unspecified.
        _writingProtectionOption = NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication;
#endif
        
        _metadata = [[NSMutableDictionary alloc] init];
        _diskStateKnown = NO;
        _oldestUse = DBL_MAX; // Vibe: no entry yet
        _countedFiles.counting = YES; // Vibe: the launch's count runs
      
        _cacheURL = [[self class] cacheURLWithRootPath:rootPath prefix:_prefix name:_name];
        
        //setup serializers
        if(serializer) {
            _serializer = [serializer copy];
        } else {
            _serializer = self.defaultSerializer;
        }

        if(deserializer) {
            _deserializer = [deserializer copy];
        } else {
            _deserializer = self.defaultDeserializer;
        }
        
        //setup key encoder/decoder
        if(keyEncoder) {
            _keyEncoder = [keyEncoder copy];
        } else {
            _keyEncoder = self.defaultKeyEncoder;
        }
        
        if(keyDecoder) {
            _keyDecoder = [keyDecoder copy];
        } else {
            _keyDecoder = self.defaultKeyDecoder;
        }
        
        pthread_cond_init(&_diskWritableCondition, NULL);
        pthread_cond_init(&_diskStateKnownCondition, NULL);

        //we don't want to do anything without setting up the disk cache, but we also don't want to block init, it can take a while to initialize. This must *not* be done on _operationQueue because other operations added may hold the lock and fill up the queue.
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self lock];
                [self _locked_createCacheDirectory];
            [self unlock];
            [self initializeDiskProperties];
        });
    }
    return self;
}

- (NSString *)description
{
    return [[NSString alloc] initWithFormat:@"%@.%@.%p", PINDiskCachePrefix, _name, (__bridge void *)self];
}

+ (PINDiskCache *)sharedCache
{
    static PINDiskCache *cache;
    static dispatch_once_t predicate;
    
    dispatch_once(&predicate, ^{
        cache = [[PINDiskCache alloc] initWithName:PINDiskCacheSharedName];
    });
    
    return cache;
}

+ (NSURL *)cacheURLWithRootPath:(NSString *)rootPath prefix:(NSString *)prefix name:(NSString *)name
{
    NSString *pathComponent = [[NSString alloc] initWithFormat:@"%@.%@", prefix, name];
    return [NSURL fileURLWithPathComponents:@[ rootPath, pathComponent ]];
}

#pragma mark - Private Methods -

- (NSURL *)encodedFileURLForKey:(NSString *)key
{
    if (![key length])
        return nil;
    
    //Significantly improve performance by indicating that the URL will *not* result in a directory.
    //Also note that accessing _cacheURL is safe without the lock because it is only set on init.
    return [_cacheURL URLByAppendingPathComponent:[self encodedString:key] isDirectory:NO];
}

- (NSString *)keyForEncodedFileURL:(NSURL *)url
{
    NSString *fileName = [url lastPathComponent];
    if (!fileName)
        return nil;
    
    return [self decodedString:fileName];
}

- (NSString *)encodedString:(NSString *)string
{
    return _keyEncoder(string);
}

- (NSString *)decodedString:(NSString *)string
{
    return _keyDecoder(string);
}

- (PINDiskCacheSerializerBlock)defaultSerializer
{
    return ^NSData*(id<NSCoding> object, NSString *key){
        NSError *error = nil;
        NSData *data = [NSKeyedArchiver archivedDataWithRootObject:object requiringSecureCoding:NO error:&error];
        PINDiskCacheError(error);
        return data;
    };
}

- (PINDiskCacheDeserializerBlock)defaultDeserializer
{
    return ^id(NSData * data, NSString *key){
        NSError *error = nil;
        NSKeyedUnarchiver *unarchiver = [[NSKeyedUnarchiver alloc] initForReadingFromData:data error:&error];
        NSAssert(!error, @"unarchiver init failed with error");
        unarchiver.requiresSecureCoding = NO;
        return [unarchiver decodeObjectForKey:NSKeyedArchiveRootObjectKey];
    };
}

- (PINDiskCacheKeyEncoderBlock)defaultKeyEncoder
{
    return ^NSString *(NSString *decodedKey) {
        if (![decodedKey length]) {
            return @"";
        }
        
        NSString *encodedString = [decodedKey stringByAddingPercentEncodingWithAllowedCharacters:[[NSCharacterSet characterSetWithCharactersInString:@".:/%"] invertedSet]];
        return encodedString;
    };
}

- (PINDiskCacheKeyEncoderBlock)defaultKeyDecoder
{
    return ^NSString *(NSString *encodedKey) {
        if (![encodedKey length]) {
            return @"";
        }
        
        return [encodedKey stringByRemovingPercentEncoding];
    };
}


#pragma mark - Private Trash Methods -

+ (dispatch_queue_t)sharedTrashQueue
{
    static dispatch_queue_t trashQueue;
    static dispatch_once_t predicate;
    
    dispatch_once(&predicate, ^{
        NSString *queueName = [[NSString alloc] initWithFormat:@"%@.trash", PINDiskCachePrefix];
        trashQueue = dispatch_queue_create([queueName UTF8String], DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(trashQueue, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0));
    });
    
    return trashQueue;
}

+ (NSLock *)sharedLock
{
    static NSLock *sharedLock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedLock = [NSLock new];
    });
    return sharedLock;
}

+ (NSURL *)sharedTrashURL
{
    NSAssert(![[PINDiskCache sharedLock] tryLock] || ([[PINDiskCache sharedLock] unlock], NO),
             @"+[sharedTrashURL] must be called with +[sharedLock] held.");
    if (_sharedTrashURL == nil) {
        NSString *uniqueString = [[NSProcessInfo processInfo] globallyUniqueString];
        _sharedTrashURL = [[[NSURL alloc] initFileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:uniqueString isDirectory:YES];

        NSError *error = nil;
        [[NSFileManager defaultManager] createDirectoryAtURL:_sharedTrashURL
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:&error];
        PINDiskCacheError(error);
    }
    return _sharedTrashURL;
}

+ (BOOL)moveItemAtURLToTrashOrRemove:(NSURL *)itemURL
{
    if (![[NSFileManager defaultManager] fileExistsAtPath:[itemURL path]])
        return NO;
    
    NSError *error = nil;
    NSString *uniqueString = [[NSProcessInfo processInfo] globallyUniqueString];

    [[PINDiskCache sharedLock] lock];
        NSURL *uniqueTrashURL = [[PINDiskCache sharedTrashURL] URLByAppendingPathComponent:uniqueString
                                                                               isDirectory:NO];
        BOOL moved = [[NSFileManager defaultManager] moveItemAtURL:itemURL toURL:uniqueTrashURL error:&error];
    [[PINDiskCache sharedLock] unlock];
    PINDiskCacheError(error);
    BOOL removed = NO;
    if (!moved) {
        // Delete the item synchronously as a fallback.
        removed = [[NSFileManager defaultManager] removeItemAtURL:itemURL error:&error];
        PINDiskCacheError(error);
    }
    return moved || removed;
}

+ (void)emptyTrash
{
    dispatch_async([PINDiskCache sharedTrashQueue], ^{
        NSURL *trashURL = nil;
      
        // If _sharedTrashURL is unset, there's nothing left to do because it hasn't been accessed and therefore items haven't been added to it.
        // If it is set, we can just remove it.
        // We also need to nil out _sharedTrashURL so that a new one will be created if there's an attempt to move a new file to the trash.
        [[PINDiskCache sharedLock] lock];
            if (_sharedTrashURL != nil) {
                trashURL = _sharedTrashURL;
                _sharedTrashURL = nil;
            }
        [[PINDiskCache sharedLock] unlock];
        
        if (trashURL != nil) {
            NSError *removeTrashedItemError = nil;
            [[NSFileManager defaultManager] removeItemAtURL:trashURL error:&removeTrashedItemError];
            PINDiskCacheError(removeTrashedItemError);
        }
    });
}

#pragma mark - Private Queue Methods -

- (BOOL)_locked_createCacheDirectory
{
    BOOL created = NO;
    if ([[NSFileManager defaultManager] fileExistsAtPath:[_cacheURL path]] == NO) {
        NSError *error = nil;
        created = [[NSFileManager defaultManager] createDirectoryAtURL:_cacheURL
                                                withIntermediateDirectories:YES
                                                                 attributes:nil
                                                                      error:&error];
        PINDiskCacheError(error);
    }
    

    
    // while this may not be true if success is false, it's better than deadlocking later.
    _diskWritable = YES;
    pthread_cond_broadcast(&_diskWritableCondition);
    
    return created;
}

+ (NSArray *)resourceKeys
{
    static NSArray *resourceKeys = nil;
    static dispatch_once_t predicate;

    dispatch_once(&predicate, ^{
        resourceKeys = @[ NSURLCreationDateKey, NSURLContentModificationDateKey, NSURLTotalFileAllocatedSizeKey ];
    });

    return resourceKeys;
}

// Vibe: an entry's record read from its file, for a cache that keeps none.
// nil when the file is gone. A URL from a listing serves its prefetched
// values.
- (nullable PINDiskCacheMetadata *)recordOfFileURL:(nullable NSURL *)fileURL
{
    NSDictionary *values = [fileURL resourceValuesForKeys:[PINDiskCache resourceKeys] error:NULL];
    if (!values[NSURLTotalFileAllocatedSizeKey]) {
        return nil;
    }
    PINDiskCacheMetadata *record = [[PINDiskCacheMetadata alloc] init];
    record.createdDate = values[NSURLCreationDateKey];
    record.lastModifiedDate = values[NSURLContentModificationDateKey];
    record.size = values[NSURLTotalFileAllocatedSizeKey];
    return record;
}

// Vibe: the key's record read from its file, with no lock held.
- (nullable PINDiskCacheMetadata *)_recordForKeyUnlocked:(NSString *)key
{
    return [self recordOfFileURL:[self encodedFileURLForKey:key]];
}

// Vibe: the key's record: the one kept, or read from its file now.
// TRAP: it reads through a URL of its own, since an NSURL keeps the values it
// read, and a write's own URL would then give its old size back.
- (nullable PINDiskCacheMetadata *)_locked_recordForKey:(NSString *)key
{
    return _recordsOnDemand ? [self recordOfFileURL:[self encodedFileURLForKey:key]] : _metadata[key];
}

// Vibe: for a cache that keeps no records, every entry's record, or with a
// date, each last used before it, from a listing made once the disk state is
// known, so the byte count a sweep changes is whole, and before the sweep
// takes the lock, which the listing would hold for long. It enumerates a
// thousand files to a pool. nil for a cache that keeps records, which waits
// for nothing, as upstream's sweeps did not.
- (nullable NSDictionary<NSString *, PINDiskCacheMetadata *> *)recordsListedForSweepUsedBefore:(nullable NSDate *)date
{
    if (!self.recordsOnDemand) {
        return nil;
    }
    [self lockAndWaitForKnownState];
    [self unlock];
    NSDirectoryEnumerator<NSURL *> *files =
        [[NSFileManager defaultManager] enumeratorAtURL:_cacheURL
                             includingPropertiesForKeys:[PINDiskCache resourceKeys]
                                                options:NSDirectoryEnumerationSkipsHiddenFiles |
                                                        NSDirectoryEnumerationSkipsSubdirectoryDescendants
                                           errorHandler:^BOOL(NSURL *url, NSError *error) {
                                               PINDiskCacheError(error);
                                               return YES;
                                           }];
    NSMutableDictionary<NSString *, PINDiskCacheMetadata *> *records = [[NSMutableDictionary alloc] init];
    for (BOOL more = YES; more;) {
        @autoreleasepool {
            for (NSUInteger listed = 0; listed < 1000; listed++) {
                NSURL *fileURL = [files nextObject];
                if (!fileURL) {
                    more = NO;
                    break;
                }
                PINDiskCacheMetadata *record = [self recordOfFileURL:fileURL];
                if (!record || (date && record.lastModifiedDate && [record.lastModifiedDate compare:date] != NSOrderedAscending)) {
                    continue;
                }
                NSString *key = [self keyForEncodedFileURL:fileURL];
                if (key) {
                    records[key] = record;
                }
            }
        }
    }
    return records;
}

- (nullable NSDictionary<NSString *, PINDiskCacheMetadata *> *)recordsListedForSweep
{
    return [self recordsListedForSweepUsedBefore:nil];
}

// Vibe: whether the cache is over the size, once its disk state is known.
// A cache that keeps no records then lists nothing to trim nothing, as the
// byte and age limits' setters' trims at each launch would.
- (BOOL)needsTrimTo:(NSUInteger)trimByteCount
{
    if (!self.recordsOnDemand) {
        return YES;
    }
    [self lockAndWaitForKnownState];
        BOOL over = _byteCount > trimByteCount;
    [self unlock];
    return over;
}

// Vibe: records on demand, read under the lock.
- (BOOL)recordsOnDemand
{
    [self lock];
        BOOL onDemand = _recordsOnDemand;
    [self unlock];
    return onDemand;
}

- (void)setRecordsOnDemand:(BOOL)recordsOnDemand
{
    // Vibe: one way, since nothing reads the records back. And for a
    // least-recently-used cache only, not a TTL one, as no record keeps an
    // access count or an object's own age limit.
    NSAssert(recordsOnDemand || !self.recordsOnDemand, @"Records on demand can't be turned off.");
    NSAssert(!recordsOnDemand || (!self.isTTLCache && self.evictionStrategy == PINCacheEvictionStrategyLeastRecentlyUsed),
             @"Records on demand are for a least-recently-used cache that is not a TTL cache.");
    if (!recordsOnDemand || self.isTTLCache || self.evictionStrategy != PINCacheEvictionStrategyLeastRecentlyUsed) {
        return;
    }
    [self lock];
        __atomic_store_n(&_recordsOnDemand, YES, __ATOMIC_RELEASE);
        // The records it drops lower the oldest date, for the files the
        // launch's count read before the mode.
        for (PINDiskCacheMetadata *record in _metadata.objectEnumerator) {
            _oldestUse = MIN(_oldestUse, record.lastModifiedDate ? record.lastModifiedDate.timeIntervalSinceReferenceDate : 0);
        }
        // A launch's count still running skips the files its records were of.
        if (_countedFiles.counting) {
            for (NSString *key in _metadata) {
                PINDiskCacheFileSetAdd(&_countedFiles, [self fileNameHashForKey:key]);
            }
        }
        [_metadata removeAllObjects];
    [self unlock];
}

/**
 * @return File size in bytes.
 */
- (NSUInteger)_locked_initializeDiskPropertiesForFile:(NSURL *)fileURL fileKey:(NSString *)fileKey
{
    NSError *error = nil;

    NSDictionary *dictionary = [fileURL resourceValuesForKeys:[PINDiskCache resourceKeys] error:&error];
    PINDiskCacheError(error);

    // Vibe: a cache that keeps no records only counts the file's bytes.
    if (_recordsOnDemand) {
        return [dictionary[NSURLTotalFileAllocatedSizeKey] unsignedIntegerValue];
    }

    if (_metadata[fileKey] == nil) {
        _metadata[fileKey] = [[PINDiskCacheMetadata alloc] init];
    }

    NSDate *createdDate = dictionary[NSURLCreationDateKey];
    if (createdDate && fileKey)
        _metadata[fileKey].createdDate = createdDate;

    NSDate *lastModifiedDate = dictionary[NSURLContentModificationDateKey];
    if (lastModifiedDate && fileKey)
        _metadata[fileKey].lastModifiedDate = lastModifiedDate;

    NSNumber *fileSize = dictionary[NSURLTotalFileAllocatedSizeKey];
    if (fileSize) {
        _metadata[fileKey].size = fileSize;
    }

    if (_ttlCache) {
        NSTimeInterval ageLimit;
        ssize_t res = getxattr(PINDiskCacheFileSystemRepresentation(fileURL), PINDiskCacheAgeLimitAttributeName, &ageLimit, sizeof(NSTimeInterval), 0, 0);
        if(res > 0) {
            _metadata[fileKey].ageLimit = ageLimit;
        } else if (res == -1) {
            // Ignore if the extended attribute was never recorded for this file.
            if (errno != ENOATTR) {
                NSDictionary<NSErrorUserInfoKey, id> *userInfo = @{ PINDiskCacheErrorReadFailureCodeKey : @(errno)};
                error = [NSError errorWithDomain:PINDiskCacheErrorDomain code:PINDiskCacheErrorReadFailure userInfo:userInfo];
                PINDiskCacheError(error);
            }
        }
    }
    
    // Vibe: the count orders only least-frequently-used eviction, so no other
    // strategy pays a getxattr per file at launch.
    if (_evictionStrategy != PINCacheEvictionStrategyLeastFrequentlyUsed) {
        return [fileSize unsignedIntegerValue];
    }

    NSInteger accessCount = 0;
    ssize_t accessCountResult = getxattr(PINDiskCacheFileSystemRepresentation(fileURL), PINDiskCacheAccessCountAttributeName, &accessCount, sizeof(NSInteger), 0, 0);
    if(accessCountResult > 0) {
        _metadata[fileKey].accessCount = accessCount;
    } else if (accessCountResult == -1) {
        // Ignore if the extended attribute was never recorded for this file.
        if (errno != ENOATTR) {
            NSDictionary<NSErrorUserInfoKey, id> *userInfo = @{ PINDiskCacheErrorReadFailureCodeKey : @(errno)};
            error = [NSError errorWithDomain:PINDiskCacheErrorDomain code:PINDiskCacheErrorReadFailure userInfo:userInfo];
            PINDiskCacheError(error);
        }
    }

    return [fileSize unsignedIntegerValue];
}

// Vibe: the hash the launch's count gives the key's file. TRAP: it hashes the
// name as written, so keys that differ only in case, one file on a
// case-insensitive volume, would each count it.
- (uint64_t)fileNameHashForKey:(NSString *)key
{
    return PINDiskCacheFileNameHash([self encodedFileURLForKey:key].lastPathComponent);
}

// Vibe: while a cache that keeps no records counts its files at launch, a
// write, a removal, or a move first settles each key it changes: unless the
// count or an earlier change accounted for the key's file, its bytes are
// added now, and the count then skips it. The change then adjusts the byte
// count as it would once the count is done, so it never waits for the count.
// A set that could not grow settles nothing more: the change waits for the
// count, as every change once did, so no file goes uncounted or counts twice.
- (void)_locked_settleKeyDuringCount:(NSString *)key
{
    if (!_countedFiles.counting || !_recordsOnDemand) {
        return;
    }
    PINDiskCacheFileSetResult result = PINDiskCacheFileSetAdd(&_countedFiles, [self fileNameHashForKey:key]);
    if (result == PINDiskCacheFileSetPresent) {
        return;
    }
    if (result == PINDiskCacheFileSetUnstored) {
        while (_diskStateKnown == NO) {
            pthread_cond_wait(&_diskStateKnownCondition, &_mutex);
        }
        return;
    }
    PINDiskCacheMetadata *record = [self _locked_recordForKey:key];
    if (record) {
        self.byteCount = _byteCount + record.size.unsignedIntegerValue; // atomic
        _oldestUse = MIN(_oldestUse, record.lastModifiedDate ? record.lastModifiedDate.timeIntervalSinceReferenceDate : 0);
    }
}

- (void)initializeDiskProperties
{
    // Vibe: the directory is read as it is enumerated, a thousand files to a
    // pool, not listed into one array, which held about 160 MB of URLs at
    // 200,000 entries, and with no lock held for the listing. A cache that
    // keeps no records notes its oldest entry's date as it counts. Each file
    // adds to the byte count as it is counted, so a change during the count
    // adds to the same count.
    PINDiskCacheCallCountSeam(self, VibePINDiskCacheCountStageStart, nil);
    NSDirectoryEnumerator<NSURL *> *files =
        [[NSFileManager defaultManager] enumeratorAtURL:_cacheURL
                             includingPropertiesForKeys:[PINDiskCache resourceKeys]
                                                options:NSDirectoryEnumerationSkipsHiddenFiles |
                                                        NSDirectoryEnumerationSkipsSubdirectoryDescendants
                                           errorHandler:^BOOL(NSURL *url, NSError *error) {
                                               PINDiskCacheError(error);
                                               return YES;
                                           }];
    for (BOOL more = YES; more;) {
        @autoreleasepool {
            for (NSUInteger counted = 0; counted < 1000; counted++) {
                NSURL *fileURL = [files nextObject];
                if (!fileURL) {
                    more = NO;
                    break;
                }
                NSString *fileKey = [self keyForEncodedFileURL:fileURL];
                PINDiskCacheCallCountSeam(self, VibePINDiskCacheCountStageFile, fileKey);
                // Continually grab and release lock while processing files to avoid contention
                [self lock];
                // Vibe: every entry was removed, so none it lists is left.
                if (!_countedFiles.counting) {
                    [self unlock];
                    more = NO;
                    break;
                }
                if (_recordsOnDemand) {
                    // Vibe: a file a change settled is skipped, as its listed
                    // values may be older than the change. One the set could
                    // not store is counted, as changes wait from then on.
                    if (PINDiskCacheFileSetAdd(&_countedFiles, PINDiskCacheFileNameHash(fileURL.lastPathComponent)) != PINDiskCacheFileSetPresent) {
                        NSDate *used = nil;
                        [fileURL getResourceValue:&used forKey:NSURLContentModificationDateKey error:NULL];
                        _oldestUse = MIN(_oldestUse, used ? used.timeIntervalSinceReferenceDate : 0);
                        self.byteCount = _byteCount + [self _locked_initializeDiskPropertiesForFile:fileURL fileKey:fileKey]; // atomic
                    }
                } else if (_metadata[fileKey] == nil) {
                    self.byteCount = _byteCount + [self _locked_initializeDiskPropertiesForFile:fileURL fileKey:fileKey]; // atomic
                }
                [self unlock];
            }
        }
    }
    PINDiskCacheCallCountSeam(self, VibePINDiskCacheCountStageEnd, nil);
    
    [self lock];
        PINDiskCacheFileSetEnd(&_countedFiles); // Vibe: the count is done.
    
        if (self->_byteLimit > 0 && self->_byteCount > self->_byteLimit)
            [self trimToSizeByEvictionStrategyAsync:PINDiskCacheTrimTarget(self->_byteLimit) completion:nil];

        if (self->_ttlCache)
            [self removeExpiredObjectsAsync:nil];
    
        _diskStateKnown = YES;
        pthread_cond_broadcast(&_diskStateKnownCondition);
    [self unlock];
}

- (void)asynchronouslySetFileModificationDate:(NSDate *)date forURL:(NSURL *)fileURL
{
    [self.operationQueue scheduleOperation:^{
        [self lockForWriting];
            [self _locked_setFileModificationDate:date forURL:fileURL];
        [self unlock];
    } withPriority:PINOperationQueuePriorityLow];
}

- (BOOL)_locked_setFileModificationDate:(NSDate *)date forURL:(NSURL *)fileURL
{
    if (!date || !fileURL) {
        return NO;
    }
    
    NSError *error = nil;
    BOOL success = [[NSFileManager defaultManager] setAttributes:@{ NSFileModificationDate: date }
                                                    ofItemAtPath:[fileURL path]
                                                           error:&error];
    PINDiskCacheError(error);
    
    return success;
}

- (void)asynchronouslySetAgeLimit:(NSTimeInterval)ageLimit forURL:(NSURL *)fileURL
{
    [self.operationQueue scheduleOperation:^{
        [self lockForWriting];
            [self _locked_setAgeLimit:ageLimit forURL:fileURL];
        [self unlock];
    } withPriority:PINOperationQueuePriorityLow];
}

- (BOOL)_locked_setAgeLimit:(NSTimeInterval)ageLimit forURL:(NSURL *)fileURL
{
    if (!fileURL) {
        return NO;
    }

    NSError *error = nil;
    if (ageLimit <= 0.0) {
        if (removexattr(PINDiskCacheFileSystemRepresentation(fileURL), PINDiskCacheAgeLimitAttributeName, 0) != 0) {
          // Ignore if the extended attribute was never recorded for this file.
          if (errno != ENOATTR) {
            NSDictionary<NSErrorUserInfoKey, id> *userInfo = @{ PINDiskCacheErrorWriteFailureCodeKey : @(errno)};
            error = [NSError errorWithDomain:PINDiskCacheErrorDomain code:PINDiskCacheErrorWriteFailure userInfo:userInfo];
            PINDiskCacheError(error);
          }
        }
    } else {
        if (setxattr(PINDiskCacheFileSystemRepresentation(fileURL), PINDiskCacheAgeLimitAttributeName, &ageLimit, sizeof(NSTimeInterval), 0, 0) != 0) {
            NSDictionary<NSErrorUserInfoKey, id> *userInfo = @{ PINDiskCacheErrorWriteFailureCodeKey : @(errno)};
            error = [NSError errorWithDomain:PINDiskCacheErrorDomain code:PINDiskCacheErrorWriteFailure userInfo:userInfo];
            PINDiskCacheError(error);
        }
    }

    if (!error) {
        NSString *key = [self keyForEncodedFileURL:fileURL];
        if (key) {
            _metadata[key].ageLimit = ageLimit;
        }
    }

    return !error;
}

- (void)asynchronouslySetAccessCount:(NSInteger)accessCount forURL:(NSURL *)fileURL
{
    // Vibe: the on-disk count feeds only the least-frequently-used eviction
    // sort. Under the default least-recently-used strategy, writing it would
    // cost one setxattr per cache hit that nothing reads back.
    if (self.evictionStrategy != PINCacheEvictionStrategyLeastFrequentlyUsed) {
        return;
    }
    [self.operationQueue scheduleOperation:^{
        [self lockForWriting];
            [self _locked_setAcessCount:accessCount forURL:fileURL];
        [self unlock];
    } withPriority:PINOperationQueuePriorityLow];
}

- (BOOL)_locked_setAcessCount:(NSInteger)accessCount forURL:(NSURL *)fileURL
{
    if (!fileURL) {
        return NO;
    }

    NSError *error = nil;
    if (accessCount <= 0) {
        if (removexattr(PINDiskCacheFileSystemRepresentation(fileURL), PINDiskCacheAccessCountAttributeName, 0) != 0) {
          // Ignore if the extended attribute was never recorded for this file.
          if (errno != ENOATTR) {
            NSDictionary<NSErrorUserInfoKey, id> *userInfo = @{ PINDiskCacheErrorWriteFailureCodeKey : @(errno)};
            error = [NSError errorWithDomain:PINDiskCacheErrorDomain code:PINDiskCacheErrorWriteFailure userInfo:userInfo];
            PINDiskCacheError(error);
          }
        }
    } else {
        if (setxattr(PINDiskCacheFileSystemRepresentation(fileURL), PINDiskCacheAccessCountAttributeName, &accessCount, sizeof(NSInteger), 0, 0) != 0) {
            NSDictionary<NSErrorUserInfoKey, id> *userInfo = @{ PINDiskCacheErrorWriteFailureCodeKey : @(errno)};
            error = [NSError errorWithDomain:PINDiskCacheErrorDomain code:PINDiskCacheErrorWriteFailure userInfo:userInfo];
            PINDiskCacheError(error);
        }
    }

    if (!error) {
        NSString *key = [self keyForEncodedFileURL:fileURL];
        if (key) {
            _metadata[key].accessCount = accessCount;
        }
    }

    return !error;
}

- (BOOL)removeFileAndExecuteBlocksForKey:(NSString *)key
{
    return [self removeFileAndExecuteBlocksForKey:key madeAt:nil];
}

// Vibe: with a date, the file goes only while it is the one made then. A write
// replaces the file with one made later, so a write since a sweep's listing,
// or since a hit read a file that won't decode, keeps its entry.
- (BOOL)removeFileAndExecuteBlocksForKey:(NSString *)key madeAt:(nullable NSDate *)createdDate
{
    return [self removeFileAndExecuteBlocksForKey:key madeAt:createdDate usedAt:nil];
}

// Vibe: with a last use too, the file goes only while it was last used then,
// so a hit that re-dated it since the age limit's listing keeps its entry.
- (BOOL)removeFileAndExecuteBlocksForKey:(NSString *)key madeAt:(nullable NSDate *)createdDate usedAt:(nullable NSDate *)lastModifiedDate
{
    NSURL *fileURL = [self encodedFileURLForKey:key];
    if (!fileURL) {
        return NO;
    }

    // We only need to lock until writable at the top because once writable, always writable
    // Vibe: the key is settled, so the removal never waits for the launch's count.
    [self lockForWriting];
        [self _locked_settleKeyDuringCount:key];
        if (![[NSFileManager defaultManager] fileExistsAtPath:[fileURL path]]) {
            [self unlock];
            return NO;
        }
    
        PINDiskCacheObjectBlock willRemoveObjectBlock = _willRemoveObjectBlock;
        if (willRemoveObjectBlock) {
            [self unlock];
            willRemoveObjectBlock(self, key, nil);
            [self lock];
        }

        // Vibe: its size, read before the file goes, for a cache that keeps no records.
        PINDiskCacheMetadata *record = [self _locked_recordForKey:key];
        if ((createdDate && !PINDiskCacheSameFileDate(record.createdDate, createdDate))
                || (lastModifiedDate && !PINDiskCacheSameFileDate(record.lastModifiedDate, lastModifiedDate))) {
            [self unlock];
            return NO;
        }
        NSNumber *byteSize = record.size;
        BOOL trashed = [PINDiskCache moveItemAtURLToTrashOrRemove:fileURL];
        if (!trashed) {
            [self unlock];
            return NO;
        }
    
        [PINDiskCache emptyTrash];
        
        // Vibe: never below zero, as a count still being made at launch could go.
        if (byteSize)
            self.byteCount = _byteCount - MIN(_byteCount, [byteSize unsignedIntegerValue]); // atomic
        
        [_metadata removeObjectForKey:key];
    
        PINDiskCacheObjectBlock didRemoveObjectBlock = _didRemoveObjectBlock;
        if (didRemoveObjectBlock) {
            [self unlock];
            _didRemoveObjectBlock(self, key, nil);
            [self lock];
        }
    
    [self unlock];
    
    return YES;
}

- (void)trimDiskToSize:(NSUInteger)trimByteCount
{
    NSMutableArray *keysToRemove = nil;
    // Vibe: the records kept, or listed now, unless it is under the size.
    if (![self needsTrimTo:trimByteCount]) {
        return;
    }
    NSDictionary<NSString *, PINDiskCacheMetadata *> *listed = [self recordsListedForSweep];
    NSComparator bySize = ^NSComparisonResult(PINDiskCacheMetadata * _Nonnull obj1, PINDiskCacheMetadata * _Nonnull obj2) {
        return PINDiskCacheCompareSizes(obj1.size, obj2.size); // Vibe: nil-safe
    };
    // Vibe: a listing is the sweep's own, so it is sorted before the lock.
    NSArray *listedSorted = [listed keysSortedByValueUsingComparator:bySize];
    
    [self lockForWriting];
        NSDictionary<NSString *, PINDiskCacheMetadata *> *records = listed ?: (_recordsOnDemand ? @{} : _metadata);
        if (_byteCount > trimByteCount) {
            keysToRemove = [[NSMutableArray alloc] init];
            
            NSArray *keysSortedBySize = listedSorted ?: [records keysSortedByValueUsingComparator:bySize];
            
            NSUInteger bytesSaved = 0;
            for (NSString *key in [keysSortedBySize reverseObjectEnumerator]) { // largest objects first
                [keysToRemove addObject:key];
                NSNumber *byteSize = records[key].size;
                if (byteSize) {
                    bytesSaved += [byteSize unsignedIntegerValue];
                }
                if (bytesSaved >= _byteCount || _byteCount - bytesSaved <= trimByteCount) { // Vibe: never wraps
                    break;
                }
            }
        }
    [self unlock];
    
    // Vibe: a listed entry written again since goes no more. A hit since the
    // listing leaves the file's creation date, so its entry still goes.
    for (NSString *key in keysToRemove) {
        [self removeFileAndExecuteBlocksForKey:key madeAt:listed[key].createdDate];
    }
}

// This is the default trimming method which happens automatically
- (void)trimDiskToSizeByEvictionStrategy:(NSUInteger)trimByteCount
{
    if (self.isTTLCache) {
        [self removeExpiredObjects];
    }

    NSMutableArray *keysToRemove = nil;
    // Vibe: the records kept, or listed now, unless it is under the size.
    if (![self needsTrimTo:trimByteCount]) {
        return;
    }
    NSDictionary<NSString *, PINDiskCacheMetadata *> *listed = [self recordsListedForSweep];
    // Vibe: a listing is the sweep's own, so it is sorted before the lock. A
    // cache that keeps no records is least-recently-used.
    NSArray *listedSorted = [listed keysSortedByValueUsingComparator:^NSComparisonResult(PINDiskCacheMetadata * _Nonnull obj1, PINDiskCacheMetadata * _Nonnull obj2) {
        return PINDiskCacheCompareDates(obj1.lastModifiedDate, obj2.lastModifiedDate); // Vibe: nil-safe
    }];
  
    [self lockForWriting];
        NSDictionary<NSString *, PINDiskCacheMetadata *> *records = listed ?: (_recordsOnDemand ? @{} : _metadata);
        if (_byteCount > trimByteCount) {
            PINCacheEvictionStrategy strategy = self->_evictionStrategy;
            keysToRemove = [[NSMutableArray alloc] init];
            
            // last modified represents last access.
            NSArray *keysSortedByEvictionStrategy = listedSorted;
            if (!keysSortedByEvictionStrategy) switch (strategy) {
                case PINCacheEvictionStrategyLeastRecentlyUsed:
                    keysSortedByEvictionStrategy = [records keysSortedByValueUsingComparator:^NSComparisonResult(PINDiskCacheMetadata * _Nonnull obj1, PINDiskCacheMetadata * _Nonnull obj2) {
                        return PINDiskCacheCompareDates(obj1.lastModifiedDate, obj2.lastModifiedDate); // Vibe: nil-safe
                    }];
                    break;
                    
                case PINCacheEvictionStrategyLeastFrequentlyUsed:
                    keysSortedByEvictionStrategy = [records keysSortedByValueUsingComparator:^NSComparisonResult(PINDiskCacheMetadata * _Nonnull obj1, PINDiskCacheMetadata * _Nonnull obj2) {
                        if (obj1.accessCount < obj2.accessCount) {
                            return NSOrderedAscending;
                        } else if (obj1.accessCount > obj2.accessCount) {
                            return NSOrderedDescending;
                        } else {
                            return PINDiskCacheCompareDates(obj1.lastModifiedDate, obj2.lastModifiedDate); // Vibe: nil-safe
                        }
                    }];
                    break;
            }
            
            NSUInteger bytesSaved = 0;
            // objects accessed last first.
            for (NSString *key in keysSortedByEvictionStrategy) {
                [keysToRemove addObject:key];
                NSNumber *byteSize = records[key].size;
                if (byteSize) {
                    bytesSaved += [byteSize unsignedIntegerValue];
                }
                if (bytesSaved >= _byteCount || _byteCount - bytesSaved <= trimByteCount) { // Vibe: never wraps
                    break;
                }
            }
        }
    [self unlock];
    
    // Vibe: a listed entry written again since goes no more. A hit since the
    // listing leaves the file's creation date, so its entry still goes.
    for (NSString *key in keysToRemove) {
        [self removeFileAndExecuteBlocksForKey:key madeAt:listed[key].createdDate];
    }
}

// Vibe: outside a TTL cache, an entry's age counts from its last use, the
// date a hit moves, never from its write, as the class's notes say: "All
// access to the cache is dated". A TTL cache's entries still age from their
// creation.
static NSDate *PINDiskCacheAgeDate(PINDiskCacheMetadata *record, BOOL ttlCache)
{
    return ttlCache ? record.createdDate : record.lastModifiedDate;
}

- (void)trimDiskToDate:(NSDate *)trimDate
{
    // Vibe: the records kept, or listed now, unless no entry is that old.
    if (self.recordsOnDemand) {
        [self lockAndWaitForKnownState];
            BOOL nothingOlder = _oldestUse >= trimDate.timeIntervalSinceReferenceDate;
        [self unlock];
        if (nothingOlder) {
            return;
        }
    }
    BOOL ttlCache = self->_ttlCache;
    NSDictionary<NSString *, PINDiskCacheMetadata *> *listed = [self recordsListedForSweepUsedBefore:trimDate];
    NSComparator byAgeDate = ^NSComparisonResult(PINDiskCacheMetadata * _Nonnull obj1, PINDiskCacheMetadata * _Nonnull obj2) {
        return PINDiskCacheCompareDates(PINDiskCacheAgeDate(obj1, ttlCache), PINDiskCacheAgeDate(obj2, ttlCache)); // Vibe: nil-safe
    };
    // Vibe: a listing is the sweep's own, so it is sorted before the lock.
    NSArray *listedSorted = [listed keysSortedByValueUsingComparator:byAgeDate];
    [self lockForWriting];
        NSDictionary<NSString *, PINDiskCacheMetadata *> *records = listed ?: (_recordsOnDemand ? @{} : _metadata);
        NSArray *keysSortedByAgeDate = listedSorted ?: [records keysSortedByValueUsingComparator:byAgeDate];
    
        NSMutableArray *keysToRemove = [[NSMutableArray alloc] init];
        
        for (NSString *key in keysSortedByAgeDate) { // oldest files first
            NSDate *ageDate = PINDiskCacheAgeDate(records[key], ttlCache);
            if (!ageDate || records[key].ageLimit > 0.0)
                continue;
            
            if ([ageDate compare:trimDate] == NSOrderedAscending) { // older than trim date
                [keysToRemove addObject:key];
            } else {
                break;
            }
        }
    [self unlock];
    
    BOOL removedEvery = YES;
    for (NSString *key in keysToRemove) {
        // Vibe: a removal that failed leaves its file, unless it was gone.
        if (![self removeFileAndExecuteBlocksForKey:key madeAt:listed[key].createdDate usedAt:listed[key].lastModifiedDate]
                && [self _recordForKeyUnlocked:key]) {
            removedEvery = NO;
        }
    }
    // Vibe: every entry last used before the date is gone, so none older is left.
    if (listed && removedEvery) {
        [self lock];
            _oldestUse = MAX(_oldestUse, trimDate.timeIntervalSinceReferenceDate);
        [self unlock];
    }
}

- (void)trimToAgeLimitRecursively
{
    [self lock];
        NSTimeInterval ageLimit = _ageLimit;
    [self unlock];
    if (ageLimit == 0.0)
        return;
    
    NSDate *date = [[NSDate alloc] initWithTimeIntervalSinceNow:-ageLimit];
    [self trimToDateAsync:date completion:nil];
    
    dispatch_time_t time = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ageLimit * NSEC_PER_SEC));
    dispatch_after(time, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(void) {
        // Ensure that ageLimit is the same as when we were scheduled, otherwise, we've been
        // rescheduled (another dispatch_after was issued) and should cancel.
        BOOL shouldReschedule = YES;
        [self lock];
            if (ageLimit != self->_ageLimit) {
                shouldReschedule = NO;
            }
        [self unlock];
        
        if (shouldReschedule) {
            [self.operationQueue scheduleOperation:^{
                [self trimToAgeLimitRecursively];
            } withPriority:PINOperationQueuePriorityLow];
        }
    });
}

#pragma mark - Public Asynchronous Methods -

- (void)lockFileAccessWhileExecutingBlockAsync:(PINCacheBlock)block
{
    if (block == nil) {
      return;
    }

    [self.operationQueue scheduleOperation:^{
        [self lockForWriting];
            block(self);
        [self unlock];
    } withPriority:PINOperationQueuePriorityLow];
}

- (void)containsObjectForKeyAsync:(NSString *)key completion:(PINDiskCacheContainsBlock)block
{
    if (!key || !block)
        return;
    
    [self.operationQueue scheduleOperation:^{
        block([self containsObjectForKey:key]);
    } withPriority:PINOperationQueuePriorityLow];
}

- (void)objectForKeyAsync:(NSString *)key completion:(PINDiskCacheObjectBlock)block
{
    [self.operationQueue scheduleOperation:^{
        NSURL *fileURL = nil;
        id <NSCoding> object = [self objectForKey:key fileURL:&fileURL];
        
        block(self, key, object);
    } withPriority:PINOperationQueuePriorityLow];
}

- (void)fileURLForKeyAsync:(NSString *)key completion:(PINDiskCacheFileURLBlock)block
{
    if (block == nil) {
      return;
    }

    [self.operationQueue scheduleOperation:^{
        NSURL *fileURL = [self fileURLForKey:key];
      
        [self lockForWriting];
            block(key, fileURL);
        [self unlock];
    } withPriority:PINOperationQueuePriorityLow];
}

- (void)setObjectAsync:(id <NSCoding>)object forKey:(NSString *)key completion:(PINDiskCacheObjectBlock)block
{
    [self setObjectAsync:object forKey:key withAgeLimit:0.0 completion:(PINDiskCacheObjectBlock)block];
}

- (void)setObjectAsync:(id <NSCoding>)object forKey:(NSString *)key withAgeLimit:(NSTimeInterval)ageLimit completion:(nullable PINDiskCacheObjectBlock)block
{
    [self.operationQueue scheduleOperation:^{
        NSURL *fileURL = nil;
        [self setObject:object forKey:key withAgeLimit:ageLimit fileURL:&fileURL];
        
        if (block) {
            block(self, key, object);
        }
    } withPriority:PINOperationQueuePriorityLow];
}

- (void)setObjectAsync:(id <NSCoding>)object forKey:(NSString *)key withCost:(NSUInteger)cost completion:(nullable PINCacheObjectBlock)block
{
    [self setObjectAsync:object forKey:key completion:(PINDiskCacheObjectBlock)block];
}

- (void)setObjectAsync:(id <NSCoding>)object forKey:(NSString *)key withCost:(NSUInteger)cost ageLimit:(NSTimeInterval)ageLimit completion:(nullable PINCacheObjectBlock)block
{
    [self setObjectAsync:object forKey:key withAgeLimit:ageLimit completion:(PINDiskCacheObjectBlock)block];
}

- (void)removeObjectForKeyAsync:(NSString *)key completion:(PINDiskCacheObjectBlock)block
{
    [self.operationQueue scheduleOperation:^{
        NSURL *fileURL = nil;
        [self removeObjectForKey:key fileURL:&fileURL];
        
        if (block) {
            block(self, key, nil);
        }
    } withPriority:PINOperationQueuePriorityLow];
}

- (void)trimToSizeAsync:(NSUInteger)trimByteCount completion:(PINCacheBlock)block
{
    PINOperationBlock operation = ^(id data) {
        [self trimToSize:((NSNumber *)data).unsignedIntegerValue];
    };
  
    dispatch_block_t completion = nil;
    if (block) {
        completion = ^{
            block(self);
        };
    }
    
    [self.operationQueue scheduleOperation:operation
                              withPriority:PINOperationQueuePriorityLow
                                identifier:PINDiskCacheOperationIdentifierTrimToSize
                            coalescingData:[NSNumber numberWithUnsignedInteger:trimByteCount]
                       dataCoalescingBlock:PINDiskTrimmingSizeCoalescingBlock
                                completion:completion];
}

- (void)trimToDateAsync:(NSDate *)trimDate completion:(PINCacheBlock)block
{
    PINOperationBlock operation = ^(id data){
        [self trimToDate:(NSDate *)data];
    };
    
    dispatch_block_t completion = nil;
    if (block) {
        completion = ^{
            block(self);
        };
    }
    
    [self.operationQueue scheduleOperation:operation
                              withPriority:PINOperationQueuePriorityLow
                                identifier:PINDiskCacheOperationIdentifierTrimToDate
                            coalescingData:trimDate
                       dataCoalescingBlock:PINDiskTrimmingDateCoalescingBlock
                                completion:completion];
}

- (void)trimToSizeByEvictionStrategyAsync:(NSUInteger)trimByteCount completion:(PINCacheBlock)block
{
    PINOperationBlock operation = ^(id data){
        [self trimToSizeByEvictionStrategy:((NSNumber *)data).unsignedIntegerValue];
    };
    
    dispatch_block_t completion = nil;
    if (block) {
        completion = ^{
            block(self);
        };
    }
    
    [self.operationQueue scheduleOperation:operation
                              withPriority:PINOperationQueuePriorityLow
                                identifier:PINDiskCacheOperationIdentifierTrimToSizeByDate
                            coalescingData:[NSNumber numberWithUnsignedInteger:trimByteCount]
                       dataCoalescingBlock:PINDiskTrimmingSizeCoalescingBlock
                                completion:completion];
}

- (void)removeExpiredObjectsAsync:(PINCacheBlock)block
{
    [self.operationQueue scheduleOperation:^{
        [self removeExpiredObjects];

        if (block) {
            block(self);
        }
    } withPriority:PINOperationQueuePriorityLow];
}

- (void)removeAllObjectsAsync:(PINCacheBlock)block
{
    [self.operationQueue scheduleOperation:^{
        [self removeAllObjects];
        
        if (block) {
            block(self);
        }
    } withPriority:PINOperationQueuePriorityLow];
}

- (void)enumerateObjectsWithBlockAsync:(PINDiskCacheFileURLEnumerationBlock)block completionBlock:(PINCacheBlock)completionBlock
{
    [self.operationQueue scheduleOperation:^{
        [self enumerateObjectsWithBlock:block];
        
        if (completionBlock) {
            completionBlock(self);
        }
    } withPriority:PINOperationQueuePriorityLow];
}

#pragma mark - Public Synchronous Methods -

- (void)synchronouslyLockFileAccessWhileExecutingBlock:(PIN_NOESCAPE PINCacheBlock)block
{
    if (block) {
        [self lockForWriting];
            block(self);
        [self unlock];
    }
}

- (BOOL)containsObjectForKey:(NSString *)key
{
    [self lock];
        // Vibe: a cache that keeps no records asks the file.
        if (_recordsOnDemand || _metadata[key] != nil || _diskStateKnown == NO) {
            BOOL objectExpired = NO;
            if (self->_ttlCache && _metadata[key].createdDate != nil) {
                NSTimeInterval ageLimit = _metadata[key].ageLimit > 0.0 ? _metadata[key].ageLimit : self->_ageLimit;
                objectExpired = ageLimit > 0 && fabs([_metadata[key].createdDate timeIntervalSinceDate:[NSDate date]]) > ageLimit;
            }
            [self unlock];
            return (!objectExpired && [self fileURLForKey:key updateFileModificationDate:NO] != nil);
        }
    [self unlock];
    return NO;
}

- (nullable id<NSCoding>)objectForKey:(NSString *)key
{
    return [self objectForKey:key fileURL:nil];
}

- (id)objectForKeyedSubscript:(NSString *)key
{
    return [self objectForKey:key];
}

- (nullable id <NSCoding>)objectForKey:(NSString *)key fileURL:(NSURL **)outFileURL
{
    // Vibe: a cache that keeps no records reads straight from the file.
    if (key && PINDiskCacheKeepsNoRecords(self)) {
        return [self objectReadFromFileForKey:key fileURL:outFileURL];
    }

    [self lock];
        // Vibe: a cache that keeps no records tries the file.
        BOOL containsKey = _recordsOnDemand || _metadata[key] != nil || _diskStateKnown == NO;
    [self unlock];

    if (!key || !containsKey)
        return nil;
    
    id <NSCoding> object = nil;
    NSURL *fileURL = [self encodedFileURLForKey:key];
    
    NSDate *now = [NSDate date];
    [self lock];
        if (self->_ttlCache) {
            if (!_diskStateKnown) {
                if (_metadata[key] == nil) {
                    NSString *fileKey = [self keyForEncodedFileURL:fileURL];
                    [self _locked_initializeDiskPropertiesForFile:fileURL fileKey:fileKey];
                }
            }
        }

        NSTimeInterval ageLimit = _metadata[key].ageLimit > 0.0 ? _metadata[key].ageLimit : self->_ageLimit;
        if (!self->_ttlCache || ageLimit <= 0 || fabs([_metadata[key].createdDate timeIntervalSinceDate:now]) < ageLimit) {
            // If the cache should behave like a TTL cache, then only fetch the object if there's a valid ageLimit and  the object is still alive
            
            // Vibe: the read is outside the lock as well as the deserializing,
            // so concurrent hits (the sweep's cache checks) do not queue behind
            // each other's file read. A write replaces the file atomically and a
            // removal renames it away, so a read sees a whole file or none, and
            // a key removed meanwhile is not re-dated below.
            [self unlock];
            NSData *objectData = [[NSData alloc] initWithContentsOfFile:[fileURL path]];
          
            if (objectData) {
              @try {
                  object = _deserializer(objectData, key);
              }
              @catch (NSException *exception) {
                  // Vibe: removed as any entry is, so the byte count follows.
                  [self removeFileAndExecuteBlocksForKey:key];
                  PINDiskCacheException(exception);
              }
            }
            // Vibe: a cache that keeps no records reads the file's dates, outside
            // the lock as the file was read.
            PINDiskCacheMetadata *onDisk = object && self->_recordsOnDemand ? [self recordOfFileURL:fileURL] : nil;
            [self lock];
            if (object) {
                PINDiskCacheMetadata *record = self->_recordsOnDemand ? onDisk : _metadata[key];
                if (record && PINDiskCacheShouldTouch(record.lastModifiedDate, now)) {
                    _metadata[key].lastModifiedDate = now;
                    [self asynchronouslySetFileModificationDate:now forURL:fileURL];
                }
                NSInteger accessCount = _metadata[key].accessCount;
                if (accessCount < NSIntegerMax) {
                    accessCount += 1;
                    _metadata[key].accessCount = accessCount;
                    [self asynchronouslySetAccessCount:accessCount forURL:fileURL];
                }
            }
        }
    [self unlock];
    
    if (outFileURL) {
        *outFileURL = fileURL;
    }
    
    return object;
}

// Vibe: a hit for a cache that keeps no records, with no lock taken: one
// open, the dates from the file it read, and no second stat. A write replaces
// the file atomically and a removal renames it away, so the read sees a whole
// file or none. Only a re-date, once a day, asks whether the file is still
// there, so a key removed meanwhile is not re-dated.
- (nullable id <NSCoding>)objectReadFromFileForKey:(NSString *)key fileURL:(NSURL **)outFileURL
{
    NSURL *fileURL = [self encodedFileURLForKey:key];
    if (outFileURL) {
        *outFileURL = fileURL;
    }
    NSDate *createdDate = nil;
    NSDate *lastModifiedDate = nil;
    NSData *objectData = PINDiskCacheReadFile(fileURL, &createdDate, &lastModifiedDate);
    if (!objectData) {
        return nil;
    }
    id <NSCoding> object = nil;
    @try {
        object = _deserializer(objectData, key);
    }
    @catch (NSException *exception) {
        // Removed as any entry is, so the byte count follows, and only while
        // it is the file read.
        [self removeFileAndExecuteBlocksForKey:key madeAt:createdDate];
        PINDiskCacheException(exception);
    }
    NSDate *now = [NSDate date];
    if (object && PINDiskCacheShouldTouch(lastModifiedDate, now)
            && [[NSFileManager defaultManager] fileExistsAtPath:[fileURL path]]) {
        [self asynchronouslySetFileModificationDate:now forURL:fileURL];
    }
    return object;
}

/// Helper function to call fileURLForKey:updateFileModificationDate:
- (NSURL *)fileURLForKey:(NSString *)key
{
    // Don't update the file modification time, if self is a ttlCache
    return [self fileURLForKey:key updateFileModificationDate:!self->_ttlCache];
}

- (NSURL *)fileURLForKey:(NSString *)key updateFileModificationDate:(BOOL)updateFileModificationDate
{
    if (!key) {
        return nil;
    }
    
    NSDate *now = [NSDate date];
    NSURL *fileURL = [self encodedFileURLForKey:key];
    
    [self lockForWriting];
        if (fileURL.path && [[NSFileManager defaultManager] fileExistsAtPath:fileURL.path]) {
            if (updateFileModificationDate) {
                // Vibe: the record kept, or the file's own dates.
                if (PINDiskCacheShouldTouch([self _locked_recordForKey:key].lastModifiedDate, now)) {
                    _metadata[key].lastModifiedDate = now;
                    [self asynchronouslySetFileModificationDate:now forURL:fileURL];
                }

                NSInteger accessCount = _metadata[key].accessCount;
                if (accessCount < NSIntegerMax) {
                    accessCount += 1;
                    _metadata[key].accessCount = accessCount;
                    [self asynchronouslySetAccessCount:accessCount forURL:fileURL];
                }
            }
        } else {
            fileURL = nil;
        }
    [self unlock];
    return fileURL;
}

- (void)setObject:(id <NSCoding>)object forKey:(NSString *)key
{
    [self setObject:object forKey:key withAgeLimit:0.0];
}

- (void)setObject:(id <NSCoding>)object forKey:(NSString *)key withAgeLimit:(NSTimeInterval)ageLimit
{
    [self setObject:object forKey:key withAgeLimit:ageLimit fileURL:nil];
}

- (void)setObject:(id <NSCoding>)object forKey:(NSString *)key withCost:(NSUInteger)cost ageLimit:(NSTimeInterval)ageLimit
{
    [self setObject:object forKey:key withAgeLimit:ageLimit];
}

- (void)setObject:(id <NSCoding>)object forKey:(NSString *)key withCost:(NSUInteger)cost
{
    [self setObject:object forKey:key];
}

- (void)setObject:(id)object forKeyedSubscript:(NSString *)key
{
    if (object == nil) {
        [self removeObjectForKey:key];
    } else {
        [self setObject:object forKey:key];
    }
}

- (void)setObject:(id <NSCoding>)object forKey:(NSString *)key withAgeLimit:(NSTimeInterval)ageLimit fileURL:(NSURL **)outFileURL
{
    NSAssert(ageLimit <= 0.0 || (ageLimit > 0.0 && _ttlCache), @"ttlCache must be set to YES if setting an object-level age limit.");

    if (!key || !object)
        return;
    
    NSDataWritingOptions writeOptions = NSDataWritingAtomic;
    #if TARGET_OS_IPHONE
    if (self.writingProtectionOptionSet) {
        writeOptions |= self.writingProtectionOption;
    }
    #endif
  
    // Remain unlocked here so that we're not locked while serializing.
    NSData *data = _serializer(object, key);
    NSURL *fileURL = nil;

    NSUInteger byteLimit = self.byteLimit;
    if (data.length <= byteLimit || byteLimit == 0) {
        // The cache is large enough to fit this object (although we may need to evict others).
        fileURL = [self encodedFileURLForKey:key];
    } else {
        // The cache isn't large enough to fit this object (even if all others were evicted).
        // We should not write it to disk because it will be deleted immediately after.
        if (outFileURL) {
            *outFileURL = nil;
        }
        return;
    }

    // Vibe: the key is settled, so the write never waits for the launch's count.
    [self lockForWriting];
        [self _locked_settleKeyDuringCount:key];
        PINDiskCacheObjectBlock willAddObjectBlock = self->_willAddObjectBlock;
        if (willAddObjectBlock) {
            [self unlock];
                willAddObjectBlock(self, key, object);
            [self lock];
        }
    
        // Vibe: the size it replaces, read before the write, for a cache that
        // keeps no records.
        NSNumber *replacedSize = [self _locked_recordForKey:key].size;
        NSError *writeError = nil;
        BOOL written = [data writeToURL:fileURL options:writeOptions error:&writeError];
        PINDiskCacheError(writeError);
        
        if (written) {
            if (_metadata[key] == nil && !self->_recordsOnDemand) {
                _metadata[key] = [[PINDiskCacheMetadata alloc] init];
            }
            
            NSError *error = nil;
            NSDictionary *values = [fileURL resourceValuesForKeys:@[ NSURLCreationDateKey, NSURLContentModificationDateKey, NSURLTotalFileAllocatedSizeKey ] error:&error];
            PINDiskCacheError(error);
            
            NSNumber *diskFileSize = [values objectForKey:NSURLTotalFileAllocatedSizeKey];
            if (diskFileSize) {
                // Vibe: never below zero, as a count still being made at launch could go.
                if (replacedSize) {
                    self.byteCount = self->_byteCount - MIN(self->_byteCount, [replacedSize unsignedIntegerValue]);
                }
                self->_metadata[key].size = diskFileSize;
                self.byteCount = self->_byteCount + [diskFileSize unsignedIntegerValue]; // atomic
            }
            NSDate *createdDate = [values objectForKey:NSURLCreationDateKey];
            if (createdDate) {
                self->_metadata[key].createdDate = createdDate;
            }
            NSDate *lastModifiedDate = [values objectForKey:NSURLContentModificationDateKey];
            if (lastModifiedDate) {
                self->_metadata[key].lastModifiedDate = lastModifiedDate;
            }
            // Vibe: outside a TTL cache an object-level limit is always 0 and
            // its xattr never written, so removing it is a removexattr per
            // write for nothing.
            if (ageLimit > 0.0 || self->_ttlCache) {
                [self asynchronouslySetAgeLimit:ageLimit forURL:fileURL];
            }
            NSInteger accessCount = self->_metadata[key].accessCount;
            if (accessCount < NSIntegerMax) {
                accessCount += 1;
                self->_metadata[key].accessCount = accessCount;
                [self asynchronouslySetAccessCount:accessCount forURL:fileURL];
            }
            
            if (self->_byteLimit > 0 && self->_byteCount > self->_byteLimit)
                [self trimToSizeByEvictionStrategyAsync:PINDiskCacheTrimTarget(self->_byteLimit) completion:nil];
        } else {
            fileURL = nil;
        }
    
        PINDiskCacheObjectBlock didAddObjectBlock = self->_didAddObjectBlock;
        if (didAddObjectBlock) {
            [self unlock];
                didAddObjectBlock(self, key, object);
            [self lock];
        }
    [self unlock];
    
    if (outFileURL) {
        *outFileURL = fileURL;
    }
}

// Vibe: an entry moves to another key as one rename of its file. RENAME_EXCL
// refuses a destination that exists in the same call, so an entry already
// under toKey is never replaced. The byte count does not change.
- (BOOL)moveObjectForKey:(NSString *)key toKey:(NSString *)toKey
{
    if (!key || !toKey || [key isEqualToString:toKey])
        return NO;
    NSURL *fromURL = [self encodedFileURLForKey:key];
    NSURL *toURL = [self encodedFileURLForKey:toKey];
    if (!fromURL || !toURL)
        return NO;

    [self lockForWriting];
        // Both keys are settled, so the bytes the count added, or never will,
        // follow the file.
        [self _locked_settleKeyDuringCount:key];
        [self _locked_settleKeyDuringCount:toKey];
        BOOL moved = renamex_np(fromURL.fileSystemRepresentation, toURL.fileSystemRepresentation, RENAME_EXCL) == 0;
        if (moved) {
            PINDiskCacheMetadata *record = _metadata[key];
            [_metadata removeObjectForKey:key];
            if (record)
                _metadata[toKey] = record;
        }
    [self unlock];
    return moved;
}

- (void)removeObjectForKey:(NSString *)key
{
    [self removeObjectForKey:key fileURL:nil];
}

- (void)removeObjectForKey:(NSString *)key fileURL:(NSURL **)outFileURL
{
    if (!key)
        return;
    
    NSURL *fileURL = nil;
    
    fileURL = [self encodedFileURLForKey:key];
    
    [self removeFileAndExecuteBlocksForKey:key];
    
    if (outFileURL) {
        *outFileURL = fileURL;
    }
}

- (void)trimToSize:(NSUInteger)trimByteCount
{
    if (trimByteCount == 0) {
        [self removeAllObjects];
        return;
    }
    
    [self trimDiskToSize:trimByteCount];
}

- (void)trimToDate:(NSDate *)trimDate
{
    if (!trimDate)
        return;
    
    if ([trimDate isEqualToDate:[NSDate distantPast]]) {
        [self removeAllObjects];
        return;
    }
    
    [self trimDiskToDate:trimDate];
}

- (void)trimToSizeByEvictionStrategy:(NSUInteger)trimByteCount
{
    if (trimByteCount == 0) {
        [self removeAllObjects];
        return;
    }
    
    [self trimDiskToSizeByEvictionStrategy:trimByteCount];
}

- (void)removeExpiredObjects
{
    // Vibe: the records kept, or listed now.
    NSDictionary<NSString *, PINDiskCacheMetadata *> *listed = [self recordsListedForSweep];
    [self lockForWriting];
        NSDate *now = [NSDate date];
        NSMutableArray<NSString *> *expiredObjectKeys = [NSMutableArray array];
        [(listed ?: (_recordsOnDemand ? @{} : _metadata)) enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull key, PINDiskCacheMetadata * _Nonnull obj, BOOL * _Nonnull stop) {
            NSTimeInterval ageLimit = obj.ageLimit > 0.0 ? obj.ageLimit : self->_ageLimit;
            NSDate *expirationDate = [obj.createdDate dateByAddingTimeInterval:ageLimit];
            if ([expirationDate compare:now] == NSOrderedAscending) { // Expiration date has passed
                [expiredObjectKeys addObject:key];
            }
        }];
    [self unlock];

    for (NSString *key in expiredObjectKeys) {
        //unlock, removeFileAndExecuteBlocksForKey handles locking itself
        [self removeFileAndExecuteBlocksForKey:key];
    }
}

- (void)removeAllObjects
{
    // We don't need to know the disk state since we're just going to remove everything.
    [self lockForWriting];
        PINCacheBlock willRemoveAllObjectsBlock = self->_willRemoveAllObjectsBlock;
        if (willRemoveAllObjectsBlock) {
            [self unlock];
                willRemoveAllObjectsBlock(self);
            [self lock];
        }
    
        [PINDiskCache moveItemAtURLToTrashOrRemove:self->_cacheURL];
        [PINDiskCache emptyTrash];
        
        [self _locked_createCacheDirectory];
        
        [self->_metadata removeAllObjects];
        self.byteCount = 0; // atomic
        self->_oldestUse = DBL_MAX; // Vibe: no entry is left.
        // Vibe: and a launch's count still running stops, since the files it
        // would list are the ones this removed.
        PINDiskCacheFileSetEnd(&self->_countedFiles);
    
        PINCacheBlock didRemoveAllObjectsBlock = self->_didRemoveAllObjectsBlock;
        if (didRemoveAllObjectsBlock) {
            [self unlock];
                didRemoveAllObjectsBlock(self);
            [self lock];
        }
    
    [self unlock];
}

- (void)enumerateObjectsWithBlock:(PIN_NOESCAPE PINDiskCacheFileURLEnumerationBlock)block
{
    if (!block)
        return;
    
    // Vibe: the records kept, or listed now.
    NSDictionary<NSString *, PINDiskCacheMetadata *> *listed = [self recordsListedForSweep];
    // Vibe: a cache that keeps no records runs the block over its listing
    // with no lock held, as the listing was made. A file removed meanwhile
    // leaves its URL with no file, as one removed before the lock did.
    if (listed) {
        for (NSString *key in listed) {
            @autoreleasepool {
                BOOL stop = NO;
                block(key, [self encodedFileURLForKey:key], &stop);
                if (stop)
                    break;
            }
        }
        return;
    }
    [self lockAndWaitForKnownState];
        NSDate *now = [NSDate date];
    
        // Vibe: nothing is listed here, and a mode turned on since has no records.
        for (NSString *key in (listed ?: (_recordsOnDemand ? @{} : _metadata))) {
            NSURL *fileURL = [self encodedFileURLForKey:key];
            // If the cache should behave like a TTL cache, then only fetch the object if there's a valid ageLimit and the object is still alive
            NSDate *createdDate = _metadata[key].createdDate;
            NSTimeInterval ageLimit = _metadata[key].ageLimit > 0.0 ? _metadata[key].ageLimit : self->_ageLimit;
            if (!self->_ttlCache || ageLimit <= 0 || (createdDate && fabs([createdDate timeIntervalSinceDate:now]) < ageLimit)) {
                BOOL stop = NO;
                block(key, fileURL, &stop);
                if (stop)
                    break;
            }
        }
    [self unlock];
}

#pragma mark - Public Thread Safe Accessors -

- (PINDiskCacheObjectBlock)willAddObjectBlock
{
    PINDiskCacheObjectBlock block = nil;
    
    [self lock];
        block = _willAddObjectBlock;
    [self unlock];
    
    return block;
}

- (void)setWillAddObjectBlock:(PINDiskCacheObjectBlock)block
{
    [self.operationQueue scheduleOperation:^{
        [self lock];
            self->_willAddObjectBlock = [block copy];
        [self unlock];
    } withPriority:PINOperationQueuePriorityHigh];
}

- (PINDiskCacheObjectBlock)willRemoveObjectBlock
{
    PINDiskCacheObjectBlock block = nil;
    
    [self lock];
        block = _willRemoveObjectBlock;
    [self unlock];
    
    return block;
}

- (void)setWillRemoveObjectBlock:(PINDiskCacheObjectBlock)block
{
    [self.operationQueue scheduleOperation:^{
        [self lock];
            self->_willRemoveObjectBlock = [block copy];
        [self unlock];
    } withPriority:PINOperationQueuePriorityHigh];
}

- (PINCacheBlock)willRemoveAllObjectsBlock
{
    PINCacheBlock block = nil;
    
    [self lock];
        block = _willRemoveAllObjectsBlock;
    [self unlock];
    
    return block;
}

- (void)setWillRemoveAllObjectsBlock:(PINCacheBlock)block
{
    [self.operationQueue scheduleOperation:^{
        [self lock];
            self->_willRemoveAllObjectsBlock = [block copy];
        [self unlock];
    } withPriority:PINOperationQueuePriorityHigh];
}

- (PINDiskCacheObjectBlock)didAddObjectBlock
{
    PINDiskCacheObjectBlock block = nil;
    
    [self lock];
        block = _didAddObjectBlock;
    [self unlock];
    
    return block;
}

- (void)setDidAddObjectBlock:(PINDiskCacheObjectBlock)block
{
    [self.operationQueue scheduleOperation:^{
        [self lock];
            self->_didAddObjectBlock = [block copy];
        [self unlock];
    } withPriority:PINOperationQueuePriorityHigh];
}

- (PINDiskCacheObjectBlock)didRemoveObjectBlock
{
    PINDiskCacheObjectBlock block = nil;
    
    [self lock];
        block = _didRemoveObjectBlock;
    [self unlock];
    
    return block;
}

- (void)setDidRemoveObjectBlock:(PINDiskCacheObjectBlock)block
{
    [self.operationQueue scheduleOperation:^{
        [self lock];
            self->_didRemoveObjectBlock = [block copy];
        [self unlock];
    } withPriority:PINOperationQueuePriorityHigh];
}

- (PINCacheBlock)didRemoveAllObjectsBlock
{
    PINCacheBlock block = nil;
    
    [self lock];
        block = _didRemoveAllObjectsBlock;
    [self unlock];
    
    return block;
}

- (void)setDidRemoveAllObjectsBlock:(PINCacheBlock)block
{
    [self.operationQueue scheduleOperation:^{
        [self lock];
            self->_didRemoveAllObjectsBlock = [block copy];
        [self unlock];
    } withPriority:PINOperationQueuePriorityHigh];
}

- (NSUInteger)byteLimit
{
    NSUInteger byteLimit;
    
    [self lock];
        byteLimit = _byteLimit;
    [self unlock];
    
    return byteLimit;
}

- (void)setByteLimit:(NSUInteger)byteLimit
{
    // Vibe: set at once, and the trim reads the limit it runs under, as the
    // queue is concurrent (AGENTS.md). An unchanged limit trims nothing new.
    [self lock];
        BOOL unchanged = _byteLimit == byteLimit;
        _byteLimit = byteLimit;
    [self unlock];
    if (unchanged)
        return;
    [self.operationQueue scheduleOperation:^{
        [self lock];
            NSUInteger limit = self->_byteLimit;
        [self unlock];
        
        if (limit > 0)
            [self trimDiskToSizeByEvictionStrategy:limit];
    } withPriority:PINOperationQueuePriorityHigh];
}

- (NSTimeInterval)ageLimit
{
    NSTimeInterval ageLimit;
    
    [self lock];
        ageLimit = _ageLimit;
    [self unlock];
    
    return ageLimit;
}

- (void)setAgeLimit:(NSTimeInterval)ageLimit
{
    // Vibe: set at once, as the byte limit is. An unchanged limit starts no
    // second trim and timer.
    [self lock];
        BOOL unchanged = _ageLimit == ageLimit;
        _ageLimit = ageLimit;
    [self unlock];
    if (unchanged)
        return;
    [self.operationQueue scheduleOperation:^{
        [self trimToAgeLimitRecursively];
    } withPriority:PINOperationQueuePriorityLow];
}

- (BOOL)isTTLCache
{
    BOOL isTTLCache;
    
    [self lock];
        isTTLCache = _ttlCache;
    [self unlock];
  
    return isTTLCache;
}

#if TARGET_OS_IPHONE
- (NSDataWritingOptions)writingProtectionOption
{
    NSDataWritingOptions option;
  
    [self lock];
        option = _writingProtectionOption;
    [self unlock];
  
    return option;
}

- (void)setWritingProtectionOption:(NSDataWritingOptions)writingProtectionOption
{
  [self.operationQueue scheduleOperation:^{
      NSDataWritingOptions option = NSDataWritingFileProtectionMask & writingProtectionOption;
    
      [self lock];
          self->_writingProtectionOptionSet = YES;
          self->_writingProtectionOption = option;
      [self unlock];
  } withPriority:PINOperationQueuePriorityHigh];
}
#endif

- (void)lockForWriting
{
    [self lock];
    
    // Lock if the disk isn't writable.
    // Vibe: while, not if, since a wait can wake for nothing.
    while (_diskWritable == NO) {
        pthread_cond_wait(&_diskWritableCondition, &_mutex);
    }
}

- (void)lockAndWaitForKnownState
{
    [self lock];
    
    // Lock if the disk state isn't known.
    // Vibe: while, not if, since a wait can wake for nothing.
    while (_diskStateKnown == NO) {
        pthread_cond_wait(&_diskStateKnownCondition, &_mutex);
    }
}

- (void)lock
{
    __unused int result = pthread_mutex_lock(&_mutex);
    NSAssert(result == 0, @"Failed to lock PINDiskCache %@. Code: %d", self, result);
}

- (void)unlock
{
    __unused int result = pthread_mutex_unlock(&_mutex);
    NSAssert(result == 0, @"Failed to unlock PINDiskCache %@. Code: %d", self, result);
}

@end

@implementation PINDiskCache (Deprecated)

- (void)lockFileAccessWhileExecutingBlock:(nullable PINCacheBlock)block
{
    [self lockFileAccessWhileExecutingBlockAsync:block];
}

- (void)containsObjectForKey:(NSString *)key block:(PINDiskCacheContainsBlock)block
{
    [self containsObjectForKeyAsync:key completion:block];
}

- (void)objectForKey:(NSString *)key block:(nullable PINDiskCacheObjectBlock)block
{
    [self objectForKeyAsync:key completion:block];
}

- (void)fileURLForKey:(NSString *)key block:(nullable PINDiskCacheFileURLBlock)block
{
    [self fileURLForKeyAsync:key completion:block];
}

- (void)setObject:(id <NSCoding>)object forKey:(NSString *)key block:(nullable PINDiskCacheObjectBlock)block
{
    [self setObjectAsync:object forKey:key completion:block];
}

- (void)removeObjectForKey:(NSString *)key block:(nullable PINDiskCacheObjectBlock)block
{
    [self removeObjectForKeyAsync:key completion:block];
}

- (void)trimToDate:(NSDate *)date block:(nullable PINDiskCacheBlock)block
{
    [self trimToDateAsync:date completion:^(id<PINCaching> diskCache) {
        if (block) {
            block((PINDiskCache *)diskCache);
        }
    }];
}

- (void)trimToSize:(NSUInteger)byteCount block:(nullable PINDiskCacheBlock)block
{
    [self trimToSizeAsync:byteCount completion:^(id<PINCaching> diskCache) {
        if (block) {
            block((PINDiskCache *)diskCache);
        }
    }];
}

- (void)trimToSizeByDate:(NSUInteger)byteCount block:(nullable PINDiskCacheBlock)block
{
    [self trimToSizeAsync:byteCount completion:^(id<PINCaching> diskCache) {
        if (block) {
            block((PINDiskCache *)diskCache);
        }
    }];
}

- (void)removeAllObjects:(nullable PINDiskCacheBlock)block
{
    [self removeAllObjectsAsync:^(id<PINCaching> diskCache) {
        if (block) {
            block((PINDiskCache *)diskCache);
        }
    }];
}

- (void)enumerateObjectsWithBlock:(PINDiskCacheFileURLBlock)block completionBlock:(nullable PINDiskCacheBlock)completionBlock
{
    [self enumerateObjectsWithBlockAsync:^(NSString * _Nonnull key, NSURL * _Nullable fileURL, BOOL * _Nonnull stop) {
      block(key, fileURL);
    } completionBlock:^(id<PINCaching> diskCache) {
        if (completionBlock) {
            completionBlock((PINDiskCache *)diskCache);
        }
    }];
}

- (void)setTtlCache:(BOOL)ttlCache
{
    [self.operationQueue scheduleOperation:^{
        [self lock];
            self->_ttlCache = ttlCache;
        [self unlock];
    } withPriority:PINOperationQueuePriorityHigh];
}

- (void)trimToSizeByDate:(NSUInteger)byteCount
{
    [self trimToSizeByEvictionStrategy:byteCount];
}

- (void)trimToSizeByDateAsync:(NSUInteger)byteCount completion:(nullable PINCacheBlock)block
{
    [self trimToSizeByEvictionStrategyAsync:byteCount completion:block];
}

@end

@implementation PINDiskCacheMetadata
@end
