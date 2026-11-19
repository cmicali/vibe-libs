//
//  VibeCacheStore.m
//  vibe-libs
//

#import "VibeCacheStore.h"
#import "VibeCacheStore+Testing.h"
#import "VibeMacros.h"

#import <fcntl.h>
#import <pthread.h>
#import <sqlite3.h>
#import <stdatomic.h>
#import <sys/file.h>
#import <sys/stat.h>
#import <unistd.h>
#import <os/lock.h>

// TRAP: until the first release, a schema change edits this one schema and
// bumps the version. A store of another version is removed and made again.
static const int VibeCacheSchemaVersion = 1;

static NSString *const VibeCacheDatabaseName = @"Cache.sqlite";
static NSString *const VibeCacheLockName = @"Cache.lock";
static NSString *const VibeCacheFilesName = @"Files";
static NSString *const VibeCacheRemovedPrefix = @"Files removed ";

static const NSUInteger VibeCacheBatch = 256;
static const NSUInteger VibeCacheIdleReaders = 4;
// Each connection's page cache, in KiB (CH22).
static const int VibeCacheReaderPageCacheKiB = 256;
static const int VibeCacheWriterPageCacheKiB = 1024;
static const int64_t VibeCacheSecondsPerDay = 86400;
// The daily work waits this long after an open, so a launch does none.
static const int64_t VibeCacheMaintenanceDelay = 10;
// A read's re-dates are written together this long after the first.
static const int64_t VibeCacheTouchDelayMs = 500;

static const char *const VibeCacheSchema =
    "CREATE TABLE entries("
    "  key TEXT NOT NULL PRIMARY KEY,"
    "  format INTEGER NOT NULL,"
    "  shared TEXT,"
    "  data BLOB,"
    "  file TEXT,"
    "  size INTEGER NOT NULL,"
    "  used INTEGER NOT NULL);"
    "CREATE INDEX entries_used ON entries(used);"
    "CREATE INDEX entries_shared ON entries(shared) WHERE shared IS NOT NULL;"
    "CREATE TABLE shared("
    "  name TEXT NOT NULL,"
    "  part TEXT NOT NULL,"
    "  format INTEGER NOT NULL,"
    "  data BLOB,"
    "  file TEXT,"
    "  size INTEGER NOT NULL,"
    "  used INTEGER NOT NULL,"
    "  PRIMARY KEY(name, part));"
    "CREATE INDEX shared_used ON shared(used);"
    // A file named here may be on disk with no row that names it: one being
    // written, or one a committed change let go. An open removes them all.
    "CREATE TABLE pending(file TEXT NOT NULL PRIMARY KEY) WITHOUT ROWID;"
    "CREATE TABLE meta(name TEXT NOT NULL PRIMARY KEY, value) WITHOUT ROWID;"
    "CREATE TABLE totals(id INTEGER PRIMARY KEY CHECK (id = 0),"
    "  entries INTEGER NOT NULL, shared INTEGER NOT NULL, bytes INTEGER NOT NULL);"
    "INSERT INTO totals VALUES(0, 0, 0, 0);"
    "CREATE TRIGGER entries_insert AFTER INSERT ON entries BEGIN"
    "  UPDATE totals SET entries = entries + 1, bytes = bytes + NEW.size; END;"
    "CREATE TRIGGER entries_delete AFTER DELETE ON entries BEGIN"
    "  UPDATE totals SET entries = entries - 1, bytes = bytes - OLD.size; END;"
    "CREATE TRIGGER entries_update AFTER UPDATE OF size ON entries BEGIN"
    "  UPDATE totals SET bytes = bytes - OLD.size + NEW.size; END;"
    "CREATE TRIGGER shared_insert AFTER INSERT ON shared BEGIN"
    "  UPDATE totals SET shared = shared + 1, bytes = bytes + NEW.size; END;"
    "CREATE TRIGGER shared_delete AFTER DELETE ON shared BEGIN"
    "  UPDATE totals SET shared = shared - 1, bytes = bytes - OLD.size; END;"
    "CREATE TRIGGER shared_update AFTER UPDATE OF size ON shared BEGIN"
    "  UPDATE totals SET bytes = bytes - OLD.size + NEW.size; END;";

static BOOL VibeCacheIsDamage(int rc) {
    int primary = rc & 0xff;
    return primary == SQLITE_CORRUPT || primary == SQLITE_NOTADB;
}

static void VibeCacheBindText(sqlite3_stmt *stmt, int index, NSString *_Nullable text) {
    if (text) {
        sqlite3_bind_text(stmt, index, text.UTF8String, -1, SQLITE_TRANSIENT);
    } else {
        sqlite3_bind_null(stmt, index);
    }
}

static NSString *_Nullable VibeCacheColumnText(sqlite3_stmt *stmt, int column) {
    const unsigned char *text = sqlite3_column_text(stmt, column);
    return text ? [NSString stringWithUTF8String:(const char *)text] : nil;
}

static BOOL VibeCacheConfigure(sqlite3 *db, int pageCacheKiB) {
    sqlite3_busy_timeout(db, 5000);
    char sql[160];
    snprintf(sql, sizeof sql,
             "PRAGMA synchronous = NORMAL; PRAGMA cache_size = -%d; PRAGMA mmap_size = 0; PRAGMA temp_store = MEMORY;",
             pageCacheKiB);
    return sqlite3_exec(db, sql, NULL, NULL, NULL) == SQLITE_OK;
}

// MARK: - Hit

@implementation VibeCacheHit

- (instancetype)initWithData:(NSData *)data format:(NSInteger)format older:(BOOL)older sharedName:(nullable NSString *)sharedName {
    if ((self = [super init])) {
        _data = data;
        _format = format;
        _older = older;
        _sharedName = [sharedName copy];
    }
    return self;
}

@end

// MARK: - Reader

// One read connection and its statements. A reader is used by one thread at a
// time, borrowed from the store's pool.
@interface VibeCacheReader : NSObject {
@public
    sqlite3 *_db;
    sqlite3_stmt *_entry;
    sqlite3_stmt *_shared;
    sqlite3_stmt *_hasEntry;
    sqlite3_stmt *_hasShared;
    sqlite3_stmt *_totals;
    NSUInteger _generation;
}
@end

@implementation VibeCacheReader

- (nullable instancetype)initWithPath:(NSString *)path generation:(NSUInteger)generation {
    if ((self = [super init])) {
        _generation = generation;
        int flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX;
        if (sqlite3_open_v2(path.fileSystemRepresentation, &_db, flags, NULL) != SQLITE_OK
            || !VibeCacheConfigure(_db, VibeCacheReaderPageCacheKiB)
            || sqlite3_exec(_db, "PRAGMA query_only = 1;", NULL, NULL, NULL) != SQLITE_OK
            || ![self prepare:&_entry sql:"SELECT format, shared, data, file, size, used FROM entries WHERE key = ?1"]
            || ![self prepare:&_shared sql:"SELECT format, NULL, data, file, size, used FROM shared WHERE name = ?1 AND part = ?2"]
            || ![self prepare:&_hasEntry sql:"SELECT 1 FROM entries WHERE key = ?1"]
            || ![self prepare:&_hasShared sql:"SELECT 1 FROM shared WHERE name = ?1 AND part = ?2"]
            || ![self prepare:&_totals sql:"SELECT entries, shared, bytes FROM totals"]) {
            return nil;
        }
    }
    return self;
}

- (BOOL)prepare:(sqlite3_stmt **)stmt sql:(const char *)sql {
    return sqlite3_prepare_v3(_db, sql, -1, SQLITE_PREPARE_PERSISTENT, stmt, NULL) == SQLITE_OK;
}

- (void)dealloc {
    sqlite3_finalize(_entry);
    sqlite3_finalize(_shared);
    sqlite3_finalize(_hasEntry);
    sqlite3_finalize(_hasShared);
    sqlite3_finalize(_totals);
    sqlite3_close_v2(_db);
}

@end

// MARK: - Store

static char VibeCacheQueueKey;

@implementation VibeCacheStore {
    unsigned long long _byteLimit;  // under @synchronized(self)
    NSString *_databasePath;
    NSString *_filesPath;
    int _lockFD;
    dispatch_queue_t _queue;

    // The writer, its statements, and its bookkeeping. Queue only.
    sqlite3 *_writer;
    NSMutableDictionary<NSValue *, NSValue *> *_statements;
    NSMutableArray<NSString *> *_doomed;          // let go in the open transaction
    NSMutableArray<NSString *> *_removedPending;  // removed from disk, still listed
    NSArray<NSString *> *_clearingPending;
    BOOL _trimming;
    BOOL _maintenanceScheduled;
    BOOL _remakeScheduled;
    int64_t _maintenanceDay;
    BOOL _stopsBeforeFileRow;

    // The readers. Under _poolMutex.
    pthread_mutex_t _poolMutex;
    pthread_cond_t _poolCondition;
    NSMutableArray<VibeCacheReader *> *_idleReaders;
    NSUInteger _borrowedReaders;
    NSUInteger _generation;
    BOOL _paused;
    BOOL _closed;

    // A read's uses, written together. Under _touchLock.
    os_unfair_lock _touchLock;
    NSMutableSet<NSString *> *_touchedEntries;
    NSMutableSet<NSArray<NSString *> *> *_touchedShared;
    BOOL _touchScheduled;

    _Atomic(int64_t) _dayOffset;
}

+ (unsigned long long)defaultByteLimit {
    return 1024ULL * 1024 * 1024;
}

+ (NSTimeInterval)defaultAgeLimit {
    return 180 * VibeCacheSecondsPerDay;
}

+ (nullable instancetype)storeWithName:(NSString *)name rootPath:(nullable NSString *)rootPath {
    NSString *root = rootPath ?: NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    if (!root) {
        return nil;
    }
    return [[self alloc] initWithDirectory:[root stringByAppendingPathComponent:name]];
}

- (nullable instancetype)initWithDirectory:(NSString *)directory {
    if (!(self = [super init])) {
        return nil;
    }
    _directory = [directory copy];
    _databasePath = [directory stringByAppendingPathComponent:VibeCacheDatabaseName];
    _filesPath = [directory stringByAppendingPathComponent:VibeCacheFilesName];
    _byteLimit = VibeCacheStore.defaultByteLimit;
    _ageLimit = VibeCacheStore.defaultAgeLimit;
    _inlineLimit = 64 * 1024;
    _lockFD = -1;
    _statements = [NSMutableDictionary dictionary];
    _doomed = [NSMutableArray array];
    _removedPending = [NSMutableArray array];
    _idleReaders = [NSMutableArray array];
    _touchedEntries = [NSMutableSet set];
    _touchedShared = [NSMutableSet set];
    _touchLock = OS_UNFAIR_LOCK_INIT;
    pthread_mutex_init(&_poolMutex, NULL);
    pthread_cond_init(&_poolCondition, NULL);
    _queue = dispatch_queue_create("vibe.cache-store", dispatch_queue_attr_make_with_qos_class(
        DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    dispatch_queue_set_specific(_queue, &VibeCacheQueueKey, (__bridge void *)self, NULL);

    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm createDirectoryAtPath:_filesPath withIntermediateDirectories:YES attributes:nil error:NULL]) {
        LogError(@"VibeCacheStore: can't make %@", directory.lastPathComponent);
        _closed = YES;
        return nil;
    }
    // CH21: one open at a time. flock holds per open file, so a second open in
    // this process fails as one in another process does.
    NSString *lockPath = [directory stringByAppendingPathComponent:VibeCacheLockName];
    _lockFD = open(lockPath.fileSystemRepresentation, O_RDWR | O_CREAT | O_CLOEXEC, 0644);
    if (_lockFD < 0 || flock(_lockFD, LOCK_EX | LOCK_NB) != 0) {
        LogError(@"VibeCacheStore: %@ is open elsewhere", directory.lastPathComponent);
        _closed = YES;
        return nil;
    }
    // CH20: a cache holds nothing the user made, so one that will not open is
    // made again.
    if (![self openWriter]) {
        LogWarn(@"VibeCacheStore: remaking %@, which would not open", directory.lastPathComponent);
        [self removeDatabaseFiles];
        if (![self openWriter]) {
            LogError(@"VibeCacheStore: can't make %@", directory.lastPathComponent);
            [self closeWriter];
            _closed = YES;
            return nil;
        }
    }
    [self removePendingFiles];
    [self removeLeftFolders];

    _maintenanceScheduled = YES;
    [self scheduleMaintenance];
    return self;
}

- (void)dealloc {
    [self close];
    pthread_mutex_destroy(&_poolMutex);
    pthread_cond_destroy(&_poolCondition);
}

- (void)close {
    [self syncOnQueue:^{
        if (self->_writer) {
            [self flushTouches];
        }
        [self pauseReaders];
        [self closeWriter];
        pthread_mutex_lock(&self->_poolMutex);
        self->_closed = YES;
        self->_paused = NO;
        pthread_cond_broadcast(&self->_poolCondition);
        pthread_mutex_unlock(&self->_poolMutex);
    }];
    if (_lockFD >= 0) {
        flock(_lockFD, LOCK_UN);
        close(_lockFD);
        _lockFD = -1;
    }
}

// MARK: Queue

- (BOOL)isOnQueue {
    return dispatch_get_specific(&VibeCacheQueueKey) == (__bridge void *)self;
}

- (void)syncOnQueue:(dispatch_block_t)block {
    if ([self isOnQueue]) {
        block();
    } else {
        dispatch_sync(_queue, block);
    }
}

- (void)performAfterQueuedWork:(dispatch_block_t)block {
    dispatch_async(_queue, block);
}

// Runs step on the queue, again and again while it returns YES, then next.
// Each run is its own transaction, so a write waits for one batch at most.
- (void)repeatStep:(BOOL (^)(void))step then:(nullable dispatch_block_t)next {
    dispatch_async(_queue, ^{
        if (self->_writer && step()) {
            [self repeatStep:step then:next];
        } else if (next) {
            next();
        }
    });
}

// MARK: Days

- (int64_t)today {
    return (int64_t)floor(CFAbsoluteTimeGetCurrent() / VibeCacheSecondsPerDay)
        + atomic_load_explicit(&_dayOffset, memory_order_relaxed);
}

// MARK: The writer

- (BOOL)openWriter {
    int flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX;
    if (sqlite3_open_v2(_databasePath.fileSystemRepresentation, &_writer, flags, NULL) != SQLITE_OK) {
        [self closeWriter];
        return NO;
    }
    int version = -1;
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(_writer, "PRAGMA user_version", -1, &stmt, NULL) == SQLITE_OK
        && sqlite3_step(stmt) == SQLITE_ROW) {
        version = sqlite3_column_int(stmt, 0);
    }
    sqlite3_finalize(stmt);
    BOOL ready = NO;
    if (version == 0) {
        // auto_vacuum takes effect only before the first table.
        ready = sqlite3_exec(_writer, "PRAGMA auto_vacuum = INCREMENTAL;", NULL, NULL, NULL) == SQLITE_OK
            && [self setJournalMode]
            && sqlite3_exec(_writer, "BEGIN", NULL, NULL, NULL) == SQLITE_OK
            && sqlite3_exec(_writer, VibeCacheSchema, NULL, NULL, NULL) == SQLITE_OK
            && sqlite3_exec(_writer, [NSString stringWithFormat:@"PRAGMA user_version = %d; COMMIT;",
                                                                VibeCacheSchemaVersion].UTF8String,
                            NULL, NULL, NULL) == SQLITE_OK;
    } else if (version == VibeCacheSchemaVersion) {
        ready = [self setJournalMode];
    }
    ready = ready && VibeCacheConfigure(_writer, VibeCacheWriterPageCacheKiB)
        && sqlite3_exec(_writer, "PRAGMA journal_size_limit = 4194304; SELECT bytes FROM totals;",
                        NULL, NULL, NULL) == SQLITE_OK;
    if (!ready) {
        [self closeWriter];
        return NO;
    }
    _maintenanceDay = [self integerForMeta:@"maintenance"];
    return YES;
}

- (BOOL)setJournalMode {
    sqlite3_stmt *stmt = NULL;
    BOOL wal = NO;
    if (sqlite3_prepare_v2(_writer, "PRAGMA journal_mode = WAL", -1, &stmt, NULL) == SQLITE_OK
        && sqlite3_step(stmt) == SQLITE_ROW) {
        wal = [VibeCacheColumnText(stmt, 0) isEqualToString:@"wal"];
    }
    sqlite3_finalize(stmt);
    return wal;
}

- (void)closeWriter {
    for (NSValue *value in _statements.allValues) {
        sqlite3_finalize(value.pointerValue);
    }
    [_statements removeAllObjects];
    if (_writer) {
        sqlite3_close_v2(_writer);
        _writer = NULL;
    }
}

// The database, its journal, and its folder of files. The folder is renamed,
// then removed off the queue. An open removes one a crash left.
- (void)removeDatabaseFiles {
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *suffix in @[@"", @"-wal", @"-shm"]) {
        [fm removeItemAtPath:[_databasePath stringByAppendingString:suffix] error:NULL];
    }
    NSString *removed = [_directory stringByAppendingPathComponent:
        [VibeCacheRemovedPrefix stringByAppendingString:NSUUID.UUID.UUIDString]];
    if ([fm moveItemAtPath:_filesPath toPath:removed error:NULL]) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
            [NSFileManager.defaultManager removeItemAtPath:removed error:NULL];
        });
    } else {
        [fm removeItemAtPath:_filesPath error:NULL];
    }
    [fm createDirectoryAtPath:_filesPath withIntermediateDirectories:YES attributes:nil error:NULL];
}

- (void)removeLeftFolders {
    NSString *directory = _directory;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        for (NSString *name in [fm contentsOfDirectoryAtPath:directory error:NULL]) {
            if ([name hasPrefix:VibeCacheRemovedPrefix]) {
                [fm removeItemAtPath:[directory stringByAppendingPathComponent:name] error:NULL];
            }
        }
    });
}

// The files a crash or a let-go change left listed in pending. No committed
// row names one, so each goes.
- (void)removePendingFiles {
    sqlite3_stmt *stmt = [self statement:"SELECT file FROM pending"];
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        NSString *file = VibeCacheColumnText(stmt, 0);
        if (file) {
            unlink([self pathOfFile:file].fileSystemRepresentation);
        }
    }
    sqlite3_reset(stmt);
    sqlite3_exec(_writer, "DELETE FROM pending", NULL, NULL, NULL);
}

// Remakes the database after damage, or for a removal of everything.
- (void)remakeDatabase {
    [self pauseReaders];
    [self closeWriter];
    [self removeDatabaseFiles];
    [_doomed removeAllObjects];
    [_removedPending removeAllObjects];
    _clearingPending = nil;
    _trimming = NO;
    if (![self openWriter]) {
        LogError(@"VibeCacheStore: can't make %@ again", _directory.lastPathComponent);
    }
    [self resumeReaders];
}

- (void)noteResult:(int)rc {
    if (!VibeCacheIsDamage(rc)) {
        return;
    }
    [self scheduleRemake];
}

- (void)scheduleRemake {
    dispatch_async(_queue, ^{
        if (self->_remakeScheduled || !self->_writer) {
            return;
        }
        self->_remakeScheduled = YES;
        LogWarn(@"VibeCacheStore: remaking %@, which is damaged", self->_directory.lastPathComponent);
        [self remakeDatabase];
        self->_remakeScheduled = NO;
    });
}

- (sqlite3_stmt *)statement:(const char *)sql {
    NSValue *key = [NSValue valueWithPointer:sql];
    sqlite3_stmt *stmt = [_statements[key] pointerValue];
    if (!stmt) {
        if (sqlite3_prepare_v3(_writer, sql, -1, SQLITE_PREPARE_PERSISTENT, &stmt, NULL) != SQLITE_OK) {
            LogError(@"VibeCacheStore: can't prepare a statement, %s", sqlite3_errmsg(_writer));
            return NULL;
        }
        _statements[key] = [NSValue valueWithPointer:stmt];
    }
    return stmt;
}

// Steps a statement that returns no row, then resets it.
- (BOOL)run:(sqlite3_stmt *)stmt {
    if (!stmt) {
        return NO;
    }
    int rc = sqlite3_step(stmt);
    sqlite3_reset(stmt);
    sqlite3_clear_bindings(stmt);
    [self noteResult:rc];
    return rc == SQLITE_DONE;
}

- (BOOL)begin {
    if (sqlite3_exec(_writer, "BEGIN", NULL, NULL, NULL) != SQLITE_OK) {
        return NO;
    }
    // The files a past change removed from disk leave pending in this one.
    _clearingPending = [_removedPending copy];
    sqlite3_stmt *stmt = [self statement:"DELETE FROM pending WHERE file = ?1"];
    for (NSString *file in _clearingPending) {
        VibeCacheBindText(stmt, 1, file);
        [self run:stmt];
    }
    return YES;
}

- (BOOL)commit {
    int rc = sqlite3_exec(_writer, "COMMIT", NULL, NULL, NULL);
    if (rc != SQLITE_OK) {
        [self noteResult:rc];
        [self rollback];
        return NO;
    }
    [_removedPending removeObjectsInRange:NSMakeRange(0, _clearingPending.count)];
    _clearingPending = nil;
    for (NSString *file in _doomed) {
        unlink([self pathOfFile:file].fileSystemRepresentation);
        [_removedPending addObject:file];
    }
    [_doomed removeAllObjects];
    return YES;
}

- (void)rollback {
    sqlite3_exec(_writer, "ROLLBACK", NULL, NULL, NULL);
    _clearingPending = nil;
    [_doomed removeAllObjects];
}

// Lists a file that the open transaction lets go. The commit removes it.
- (void)doomFile:(nullable NSString *)file {
    if (!file) {
        return;
    }
    sqlite3_stmt *stmt = [self statement:"INSERT OR IGNORE INTO pending(file) VALUES (?1)"];
    VibeCacheBindText(stmt, 1, file);
    [self run:stmt];
    [_doomed addObject:file];
}

- (NSString *)pathOfFile:(NSString *)file {
    return [_filesPath stringByAppendingPathComponent:file];
}

- (int64_t)integerForMeta:(NSString *)name {
    sqlite3_stmt *stmt = [self statement:"SELECT value FROM meta WHERE name = ?1"];
    VibeCacheBindText(stmt, 1, name);
    int64_t value = sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : 0;
    sqlite3_reset(stmt);
    return value;
}

- (void)setInteger:(int64_t)value forMeta:(NSString *)name {
    sqlite3_stmt *stmt = [self statement:"INSERT OR REPLACE INTO meta(name, value) VALUES (?1, ?2)"];
    VibeCacheBindText(stmt, 1, name);
    sqlite3_bind_int64(stmt, 2, value);
    [self run:stmt];
}

- (unsigned long long)bytesOnQueue {
    sqlite3_stmt *stmt = [self statement:"SELECT bytes FROM totals"];
    sqlite3_int64 bytes = sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : 0;
    sqlite3_reset(stmt);
    return bytes > 0 ? (unsigned long long)bytes : 0;
}

// MARK: Files

// Lists a new file as pending, commits that, then writes the file. So a crash
// at any point leaves a file an open removes, never one no row lists.
- (nullable NSString *)writeFileForData:(NSData *)data {
    uint8_t bytes[8];
    arc4random_buf(bytes, sizeof bytes);
    NSString *file = [NSString stringWithFormat:@"%02x%02x%02x%02x%02x%02x%02x%02x", bytes[0], bytes[1], bytes[2],
                                                bytes[3], bytes[4], bytes[5], bytes[6], bytes[7]];
    if (![self begin]) {
        return nil;
    }
    sqlite3_stmt *stmt = [self statement:"INSERT OR IGNORE INTO pending(file) VALUES (?1)"];
    VibeCacheBindText(stmt, 1, file);
    if (![self run:stmt] || ![self commit]) {
        [self rollback];
        return nil;
    }
    const char *path = [self pathOfFile:file].fileSystemRepresentation;
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0644);
    BOOL written = fd >= 0;
    const uint8_t *cursor = data.bytes;
    size_t remaining = data.length;
    while (written && remaining > 0) {
        ssize_t count = write(fd, cursor, remaining);
        if (count < 0 && errno == EINTR) {
            continue;
        }
        written = count > 0;
        cursor += written ? count : 0;
        remaining -= written ? (size_t)count : 0;
    }
    if (fd >= 0) {
        written = close(fd) == 0 && written;
    }
    if (!written) {
        LogError(@"VibeCacheStore: can't write a file, errno %d", errno);
        unlink(path);
        [_removedPending addObject:file];
        return nil;
    }
    return file;
}

// The file's bytes, when its size is the row's. Sets errno to ENOENT when the
// file is gone.
static NSData *_Nullable VibeCacheReadFile(NSString *path, sqlite3_int64 size) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        return nil;
    }
    struct stat info;
    NSMutableData *data = nil;
    if (fstat(fd, &info) == 0 && info.st_size == size) {
        data = [NSMutableData dataWithLength:(NSUInteger)size];
        uint8_t *cursor = data.mutableBytes;
        size_t remaining = (size_t)size;
        while (data && remaining > 0) {
            ssize_t count = read(fd, cursor, remaining);
            if (count < 0 && errno == EINTR) {
                continue;
            }
            if (count <= 0) {
                data = nil;
                break;
            }
            cursor += count;
            remaining -= (size_t)count;
        }
    }
    close(fd);
    if (!data) {
        errno = EIO;
    }
    return data;
}

// MARK: Readers

- (nullable VibeCacheReader *)borrowReader {
    pthread_mutex_lock(&_poolMutex);
    while (_paused) {
        pthread_cond_wait(&_poolCondition, &_poolMutex);
    }
    if (_closed) {
        pthread_mutex_unlock(&_poolMutex);
        return nil;
    }
    VibeCacheReader *reader = _idleReaders.lastObject;
    if (reader) {
        [_idleReaders removeLastObject];
    }
    _borrowedReaders++;
    NSUInteger generation = _generation;
    pthread_mutex_unlock(&_poolMutex);
    if (!reader) {
        reader = [[VibeCacheReader alloc] initWithPath:_databasePath generation:generation];
        if (!reader) {
            [self returnReader:nil];
        }
    }
    return reader;
}

- (void)returnReader:(nullable VibeCacheReader *)reader {
    pthread_mutex_lock(&_poolMutex);
    _borrowedReaders--;
    if (reader && !_closed && !_paused && reader->_generation == _generation
        && _idleReaders.count < VibeCacheIdleReaders) {
        [_idleReaders addObject:reader];
        reader = nil;
    }
    pthread_cond_broadcast(&_poolCondition);
    pthread_mutex_unlock(&_poolMutex);
    // A reader not kept closes here, outside the lock.
    reader = nil;
}

// Waits for every borrowed reader, and closes the idle ones. Readers then wait
// until resumeReaders. Queue only.
- (void)pauseReaders {
    NSArray *closing = nil;
    pthread_mutex_lock(&_poolMutex);
    _paused = YES;
    while (_borrowedReaders > 0) {
        pthread_cond_wait(&_poolCondition, &_poolMutex);
    }
    closing = [_idleReaders copy];
    [_idleReaders removeAllObjects];
    pthread_mutex_unlock(&_poolMutex);
    // The idle readers close here, outside the lock.
    (void)closing;
}

- (void)resumeReaders {
    pthread_mutex_lock(&_poolMutex);
    _paused = NO;
    _generation++;
    pthread_cond_broadcast(&_poolCondition);
    pthread_mutex_unlock(&_poolMutex);
}

// MARK: Reads

- (nullable VibeCacheHit *)readKey:(nullable NSString *)key
                             name:(nullable NSString *)name
                             part:(nullable NSString *)part
                           format:(NSInteger)format
                      acceptOlder:(BOOL)acceptOlder {
    // A miss on a file that just went may be a replacement's, so it asks once more.
    for (int attempt = 0; attempt < 2; attempt++) {
        VibeCacheReader *reader = [self borrowReader];
        if (!reader) {
            return nil;
        }
        sqlite3_stmt *stmt = key ? reader->_entry : reader->_shared;
        VibeCacheBindText(stmt, 1, key ?: name);
        if (!key) {
            VibeCacheBindText(stmt, 2, part);
        }
        int rc = sqlite3_step(stmt);
        if (rc != SQLITE_ROW) {
            sqlite3_reset(stmt);
            [self returnReader:reader];
            [self noteReadResult:rc];
            return nil;
        }
        NSInteger rowFormat = (NSInteger)sqlite3_column_int64(stmt, 0);
        if (rowFormat > format || (rowFormat < format && !acceptOlder)) {
            sqlite3_reset(stmt);
            [self returnReader:reader];
            return nil;
        }
        NSString *sharedName = VibeCacheColumnText(stmt, 1);
        NSString *file = VibeCacheColumnText(stmt, 3);
        sqlite3_int64 size = sqlite3_column_int64(stmt, 4);
        int64_t used = sqlite3_column_int64(stmt, 5);
        NSData *data = nil;
        if (!file) {
            const void *bytes = sqlite3_column_blob(stmt, 2);
            int length = sqlite3_column_bytes(stmt, 2);
            data = [NSData dataWithBytes:bytes length:(NSUInteger)length];
        }
        sqlite3_reset(stmt);
        [self returnReader:reader];

        if (file) {
            data = VibeCacheReadFile([self pathOfFile:file], size);
            if (!data) {
                if (errno == ENOENT && attempt == 0) {
                    continue;
                }
                [self removeDamagedKey:key name:name part:part file:file];
                return nil;
            }
        }
        if (used < [self today]) {
            [self noteUseOfKey:key name:name part:part];
        }
        return [[VibeCacheHit alloc] initWithData:data format:rowFormat older:rowFormat < format sharedName:sharedName];
    }
    return nil;
}

// A row whose file is gone or the wrong size reads as a miss, and goes, if it
// still names that file.
- (void)removeDamagedKey:(nullable NSString *)key name:(nullable NSString *)name part:(nullable NSString *)part file:(NSString *)file {
    dispatch_async(_queue, ^{
        if (!self->_writer) {
            return;
        }
        NSString *current = nil;
        [self findRowOfKey:key name:name part:part file:&current sharedName:NULL];
        if ([current isEqualToString:file]) {
            [self removeRowOfKey:key name:name part:part];
        }
    });
}

- (void)noteReadResult:(int)rc {
    if (rc != SQLITE_DONE) {
        if (VibeCacheIsDamage(rc)) {
            [self scheduleRemake];
        }
    }
}

- (BOOL)hasRow:(BOOL)entry key:(NSString *)key part:(nullable NSString *)part {
    VibeCacheReader *reader = [self borrowReader];
    if (!reader) {
        return NO;
    }
    sqlite3_stmt *stmt = entry ? reader->_hasEntry : reader->_hasShared;
    VibeCacheBindText(stmt, 1, key);
    if (!entry) {
        VibeCacheBindText(stmt, 2, part);
    }
    int rc = sqlite3_step(stmt);
    sqlite3_reset(stmt);
    [self returnReader:reader];
    [self noteReadResult:rc];
    return rc == SQLITE_ROW;
}

- (nullable VibeCacheHit *)hitForKey:(NSString *)key format:(NSInteger)format {
    return [self readKey:key name:nil part:nil format:format acceptOlder:NO];
}

- (nullable VibeCacheHit *)hitForKey:(NSString *)key acceptingFormatsUpTo:(NSInteger)format {
    return [self readKey:key name:nil part:nil format:format acceptOlder:YES];
}

- (BOOL)hasEntryForKey:(NSString *)key {
    return [self hasRow:YES key:key part:nil];
}

- (nullable VibeCacheHit *)sharedHitForName:(NSString *)name part:(NSString *)part format:(NSInteger)format {
    return [self readKey:nil name:name part:part format:format acceptOlder:NO];
}

- (nullable VibeCacheHit *)sharedHitForName:(NSString *)name part:(NSString *)part acceptingFormatsUpTo:(NSInteger)format {
    return [self readKey:nil name:name part:part format:format acceptOlder:YES];
}

- (BOOL)hasSharedItemForName:(NSString *)name part:(NSString *)part {
    return [self hasRow:NO key:name part:part];
}

- (VibeCacheUsage)usage {
    VibeCacheUsage usage = {0, 0, 0};
    VibeCacheReader *reader = [self borrowReader];
    if (!reader) {
        return usage;
    }
    int rc = sqlite3_step(reader->_totals);
    if (rc == SQLITE_ROW) {
        usage.entries = (NSUInteger)MAX(sqlite3_column_int64(reader->_totals, 0), 0);
        usage.sharedItems = (NSUInteger)MAX(sqlite3_column_int64(reader->_totals, 1), 0);
        usage.bytes = (unsigned long long)MAX(sqlite3_column_int64(reader->_totals, 2), 0);
    }
    sqlite3_reset(reader->_totals);
    [self returnReader:reader];
    [self noteReadResult:rc == SQLITE_ROW ? SQLITE_DONE : rc];
    return usage;
}

- (void)usageWithCompletion:(void (^)(VibeCacheUsage))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        VibeCacheUsage usage = [self usage];
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(usage);
        });
    });
}

// MARK: Uses

// A read records its use once a day at most, and the writes wait a moment so
// a launch's reads share one transaction.
- (void)noteUseOfKey:(nullable NSString *)key name:(nullable NSString *)name part:(nullable NSString *)part {
    BOOL schedule = NO;
    os_unfair_lock_lock(&_touchLock);
    if (key) {
        [_touchedEntries addObject:key];
    } else if (name && part) {
        [_touchedShared addObject:@[name, part]];
    }
    if (!_touchScheduled) {
        _touchScheduled = schedule = YES;
    }
    os_unfair_lock_unlock(&_touchLock);
    if (schedule) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, VibeCacheTouchDelayMs * NSEC_PER_MSEC), _queue, ^{
            [self flushTouches];
        });
    }
}

- (void)flushTouches {
    os_unfair_lock_lock(&_touchLock);
    NSSet<NSString *> *entries = _touchedEntries;
    NSSet<NSArray<NSString *> *> *shared = _touchedShared;
    _touchedEntries = [NSMutableSet set];
    _touchedShared = [NSMutableSet set];
    _touchScheduled = NO;
    os_unfair_lock_unlock(&_touchLock);
    if (!_writer || (entries.count == 0 && shared.count == 0) || ![self begin]) {
        return;
    }
    int64_t today = [self today];
    sqlite3_stmt *stmt = [self statement:"UPDATE entries SET used = ?2 WHERE key = ?1 AND used < ?2"];
    for (NSString *key in entries) {
        VibeCacheBindText(stmt, 1, key);
        sqlite3_bind_int64(stmt, 2, today);
        [self run:stmt];
    }
    stmt = [self statement:"UPDATE shared SET used = ?3 WHERE name = ?1 AND part = ?2 AND used < ?3"];
    for (NSArray<NSString *> *pair in shared) {
        VibeCacheBindText(stmt, 1, pair[0]);
        VibeCacheBindText(stmt, 2, pair[1]);
        sqlite3_bind_int64(stmt, 3, today);
        [self run:stmt];
    }
    [self commit];
}

// MARK: Writes

- (void)setData:(NSData *)data forKey:(NSString *)key format:(NSInteger)format sharedName:(nullable NSString *)sharedName {
    [self writeData:data key:key name:nil part:nil format:format sharedName:sharedName];
}

- (void)setSharedData:(NSData *)data forName:(NSString *)name part:(NSString *)part format:(NSInteger)format {
    [self writeData:data key:nil name:name part:part format:format sharedName:nil];
}

- (void)writeData:(NSData *)data
              key:(nullable NSString *)key
             name:(nullable NSString *)name
             part:(nullable NSString *)part
           format:(NSInteger)format
       sharedName:(nullable NSString *)sharedName {
    if (!data || (!key && !(name && part))) {
        return;
    }
    BOOL toFile = data.length > self.inlineLimit;
    [self syncOnQueue:^{
        if (!self->_writer) {
            return;
        }
        NSString *file = nil;
        if (toFile) {
            file = [self writeFileForData:data];
            if (!file) {
                // A failed write leaves no entry, so the old one can't answer.
                [self removeRowOfKey:key name:name part:part];
                return;
            }
            if (self->_stopsBeforeFileRow) {
                return;
            }
        }
        if (![self begin]) {
            return;
        }
        NSString *oldFile = nil;
        NSString *oldShared = nil;
        [self findRowOfKey:key name:name part:part file:&oldFile sharedName:&oldShared];
        sqlite3_stmt *stmt;
        if (key) {
            stmt = [self statement:
                "INSERT INTO entries(key, format, shared, data, file, size, used) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7) "
                "ON CONFLICT(key) DO UPDATE SET format = excluded.format, shared = excluded.shared, "
                "data = excluded.data, file = excluded.file, size = excluded.size, used = excluded.used"];
            VibeCacheBindText(stmt, 1, key);
            VibeCacheBindText(stmt, 3, sharedName);
        } else {
            stmt = [self statement:
                "INSERT INTO shared(name, part, format, data, file, size, used) VALUES (?1, ?8, ?2, ?4, ?5, ?6, ?7) "
                "ON CONFLICT(name, part) DO UPDATE SET format = excluded.format, "
                "data = excluded.data, file = excluded.file, size = excluded.size, used = excluded.used"];
            VibeCacheBindText(stmt, 1, name);
            VibeCacheBindText(stmt, 8, part);
        }
        sqlite3_bind_int64(stmt, 2, format);
        if (file) {
            sqlite3_bind_null(stmt, 4);
        } else {
            sqlite3_bind_blob64(stmt, 4, data.bytes ?: "", data.length, SQLITE_STATIC);
        }
        VibeCacheBindText(stmt, 5, file);
        sqlite3_bind_int64(stmt, 6, (sqlite3_int64)data.length);
        sqlite3_bind_int64(stmt, 7, [self today]);
        BOOL written = [self run:stmt];
        if (written && file) {
            sqlite3_stmt *listed = [self statement:"DELETE FROM pending WHERE file = ?1"];
            VibeCacheBindText(listed, 1, file);
            written = [self run:listed];
        }
        if (written) {
            [self doomFile:oldFile];
            if (oldShared && ![oldShared isEqualToString:sharedName]) {
                [self sweepSharedName:oldShared];
            }
        }
        if (!written || ![self commit]) {
            [self rollback];
            if (file) {
                unlink([self pathOfFile:file].fileSystemRepresentation);
                [self->_removedPending addObject:file];
            }
            [self removeRowOfKey:key name:name part:part];
            return;
        }
        [self afterWrite];
    }];
}

- (void)findRowOfKey:(nullable NSString *)key
                name:(nullable NSString *)name
                part:(nullable NSString *)part
                file:(NSString *_Nullable *_Nonnull)file
          sharedName:(NSString *_Nullable *_Nullable)sharedName {
    sqlite3_stmt *stmt;
    if (key) {
        stmt = [self statement:"SELECT file, shared FROM entries WHERE key = ?1"];
        VibeCacheBindText(stmt, 1, key);
    } else {
        stmt = [self statement:"SELECT file, NULL FROM shared WHERE name = ?1 AND part = ?2"];
        VibeCacheBindText(stmt, 1, name);
        VibeCacheBindText(stmt, 2, part);
    }
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        *file = VibeCacheColumnText(stmt, 0);
        if (sharedName) {
            *sharedName = VibeCacheColumnText(stmt, 1);
        }
    }
    sqlite3_reset(stmt);
    sqlite3_clear_bindings(stmt);
}

// Removes the shared items under name once no entry names it. In the open
// transaction.
- (void)sweepSharedName:(NSString *)name {
    sqlite3_stmt *named = [self statement:"SELECT 1 FROM entries WHERE shared = ?1 LIMIT 1"];
    VibeCacheBindText(named, 1, name);
    BOOL stillNamed = sqlite3_step(named) == SQLITE_ROW;
    sqlite3_reset(named);
    if (stillNamed) {
        return;
    }
    sqlite3_stmt *files = [self statement:"SELECT file FROM shared WHERE name = ?1 AND file IS NOT NULL"];
    VibeCacheBindText(files, 1, name);
    NSMutableArray<NSString *> *doomed = [NSMutableArray array];
    while (sqlite3_step(files) == SQLITE_ROW) {
        [doomed addObject:VibeCacheColumnText(files, 0)];
    }
    sqlite3_reset(files);
    for (NSString *file in doomed) {
        [self doomFile:file];
    }
    sqlite3_stmt *remove = [self statement:"DELETE FROM shared WHERE name = ?1"];
    VibeCacheBindText(remove, 1, name);
    [self run:remove];
}

// Removes one row, its file, and a shared item it was the last to name, in
// a transaction of its own.
- (void)removeRowOfKey:(nullable NSString *)key name:(nullable NSString *)name part:(nullable NSString *)part {
    if (![self begin]) {
        return;
    }
    NSString *file = nil;
    NSString *sharedName = nil;
    [self findRowOfKey:key name:name part:part file:&file sharedName:&sharedName];
    sqlite3_stmt *stmt;
    if (key) {
        stmt = [self statement:"DELETE FROM entries WHERE key = ?1"];
        VibeCacheBindText(stmt, 1, key);
    } else {
        stmt = [self statement:"DELETE FROM shared WHERE name = ?1 AND part = ?2"];
        VibeCacheBindText(stmt, 1, name);
        VibeCacheBindText(stmt, 2, part);
    }
    [self run:stmt];
    [self doomFile:file];
    if (sharedName) {
        [self sweepSharedName:sharedName];
    }
    [self commit];
}

- (void)removeEntryForKey:(NSString *)key {
    if (!key) {
        return;
    }
    [self syncOnQueue:^{
        if (self->_writer) {
            [self removeRowOfKey:key name:nil part:nil];
        }
    }];
}

- (BOOL)moveEntryFromKey:(NSString *)oldKey toKey:(NSString *)newKey {
    if (!oldKey || !newKey) {
        return NO;
    }
    if ([oldKey isEqualToString:newKey]) {
        return [self hasEntryForKey:oldKey];
    }
    __block BOOL moved = NO;
    [self syncOnQueue:^{
        if (!self->_writer || ![self begin]) {
            return;
        }
        NSString *file = nil;
        NSString *sharedName = nil;
        [self findRowOfKey:oldKey name:nil part:nil file:&file sharedName:&sharedName];
        NSString *replacedFile = nil;
        NSString *replacedShared = nil;
        [self findRowOfKey:newKey name:nil part:nil file:&replacedFile sharedName:&replacedShared];
        sqlite3_stmt *remove = [self statement:"DELETE FROM entries WHERE key = ?1"];
        VibeCacheBindText(remove, 1, newKey);
        [self run:remove];
        sqlite3_stmt *move = [self statement:"UPDATE entries SET key = ?2 WHERE key = ?1"];
        VibeCacheBindText(move, 1, oldKey);
        VibeCacheBindText(move, 2, newKey);
        moved = [self run:move] && sqlite3_changes(self->_writer) > 0;
        if (!moved) {
            [self rollback];
            return;
        }
        [self doomFile:replacedFile];
        if (replacedShared && ![replacedShared isEqualToString:sharedName]) {
            [self sweepSharedName:replacedShared];
        }
        moved = [self commit];
    }];
    return moved;
}

- (void)removeAllWithCompletion:(nullable dispatch_block_t)completion {
    dispatch_async(_queue, ^{
        if (self->_writer) {
            [self remakeDatabase];
        }
        if (completion) {
            completion();
        }
    });
}

// MARK: Limits

- (unsigned long long)byteLimit {
    @synchronized(self) {
        return _byteLimit;
    }
}

- (void)setByteLimit:(unsigned long long)byteLimit {
    @synchronized(self) {
        _byteLimit = byteLimit;
    }
    dispatch_async(_queue, ^{
        [self afterWrite];
    });
}

- (void)afterWrite {
    if (!_writer) {
        return;
    }
    if (_maintenanceDay != [self today] && !_maintenanceScheduled) {
        _maintenanceScheduled = YES;
        [self scheduleMaintenance];
    }
    unsigned long long limit = self.byteLimit;
    if (_trimming || limit == 0 || [self bytesOnQueue] <= limit) {
        return;
    }
    _trimming = YES;
    [self repeatStep:^BOOL {
        return [self removeOldestUsedBefore:INT64_MAX untilBytes:limit / 10 * 9];
    } then:^{
        self->_trimming = NO;
    }];
}

// Removes a batch of the least recently used rows, entries and shared items
// together, used before `cutoff`, stopping once the bytes are at `target`. A
// target of 0 removes every row used before the cutoff. YES when more may
// remain.
- (BOOL)removeOldestUsedBefore:(int64_t)cutoff untilBytes:(unsigned long long)target {
    unsigned long long bytes = [self bytesOnQueue];
    if (target > 0 && bytes <= target) {
        return NO;
    }
    typedef struct {
        BOOL entry;
        sqlite3_int64 rowid;
        int64_t used;
        sqlite3_int64 size;
    } Row;
    NSMutableData *rowsData = [NSMutableData data];
    NSMutableArray<NSString *> *files = [NSMutableArray array];
    // A full batch from one table stops the merge at its last use, since the
    // rows it left may be older than the other table's.
    int64_t lastUsed = INT64_MAX;
    for (int table = 0; table < 2; table++) {
        NSUInteger fetched = 0;
        sqlite3_stmt *stmt = table == 0
            ? [self statement:"SELECT rowid, used, size, file FROM entries WHERE used < ?1 ORDER BY used LIMIT ?2"]
            : [self statement:"SELECT rowid, used, size, file FROM shared WHERE used < ?1 ORDER BY used LIMIT ?2"];
        sqlite3_bind_int64(stmt, 1, cutoff);
        sqlite3_bind_int64(stmt, 2, VibeCacheBatch);
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            Row row = {table == 0, sqlite3_column_int64(stmt, 0), sqlite3_column_int64(stmt, 1),
                       sqlite3_column_int64(stmt, 2)};
            [rowsData appendBytes:&row length:sizeof row];
            [files addObject:VibeCacheColumnText(stmt, 3) ?: @""];
            fetched++;
            if (fetched == VibeCacheBatch) {
                lastUsed = MIN(lastUsed, row.used);
            }
        }
        sqlite3_reset(stmt);
    }
    NSUInteger count = rowsData.length / sizeof(Row);
    if (count == 0) {
        return NO;
    }
    // Merge the two lists by use, oldest first. Each is sorted already.
    Row *rows = rowsData.mutableBytes;
    NSMutableArray<NSNumber *> *order = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; i++) {
        [order addObject:@(i)];
    }
    [order sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        int64_t ua = rows[a.unsignedIntegerValue].used, ub = rows[b.unsignedIntegerValue].used;
        return ua < ub ? NSOrderedAscending : (ua > ub ? NSOrderedDescending : NSOrderedSame);
    }];
    if (![self begin]) {
        return NO;
    }
    sqlite3_stmt *sharedOf = [self statement:"SELECT shared FROM entries WHERE rowid = ?1"];
    sqlite3_stmt *removeEntry = [self statement:"DELETE FROM entries WHERE rowid = ?1"];
    sqlite3_stmt *removeShared = [self statement:"DELETE FROM shared WHERE rowid = ?1"];
    NSMutableSet<NSString *> *names = [NSMutableSet set];
    NSUInteger removed = 0;
    for (NSNumber *index in order) {
        Row row = rows[index.unsignedIntegerValue];
        if ((target > 0 && bytes <= target) || row.used > lastUsed) {
            break;
        }
        if (row.entry) {
            sqlite3_bind_int64(sharedOf, 1, row.rowid);
            NSString *name = sqlite3_step(sharedOf) == SQLITE_ROW ? VibeCacheColumnText(sharedOf, 0) : nil;
            sqlite3_reset(sharedOf);
            if (name) {
                [names addObject:name];
            }
        }
        sqlite3_stmt *stmt = row.entry ? removeEntry : removeShared;
        sqlite3_bind_int64(stmt, 1, row.rowid);
        if (![self run:stmt] || sqlite3_changes(_writer) == 0) {
            continue;
        }
        NSString *file = files[index.unsignedIntegerValue];
        [self doomFile:file.length > 0 ? file : nil];
        bytes -= MIN(bytes, (unsigned long long)MAX(row.size, 0));
        removed++;
    }
    for (NSString *name in names) {
        [self sweepSharedName:name];
    }
    if (![self commit]) {
        return NO;
    }
    // Gives the freed pages back to the disk, a few megabytes at a time.
    sqlite3_exec(_writer, "PRAGMA incremental_vacuum(1024)", NULL, NULL, NULL);
    return removed > 0 && (target == 0 || [self bytesOnQueue] > target);
}

// MARK: Maintenance

- (void)scheduleMaintenance {
    __weak VibeCacheStore *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, VibeCacheMaintenanceDelay * NSEC_PER_SEC), _queue, ^{
        [weakSelf maintainIfNewDay];
    });
}

- (void)maintainIfNewDay {
    _maintenanceScheduled = NO;
    if (_writer && _maintenanceDay != [self today]) {
        [self maintainWithCompletion:nil];
    }
}

- (void)performMaintenanceWithCompletion:(nullable dispatch_block_t)completion {
    dispatch_async(_queue, ^{
        if (!self->_writer) {
            if (completion) {
                completion();
            }
            return;
        }
        [self maintainWithCompletion:completion];
    });
}

// The age limit, then the shared items no entry names, then the byte limit,
// each in batches. Queue only.
- (void)maintainWithCompletion:(nullable dispatch_block_t)completion {
    int64_t today = [self today];
    _maintenanceDay = today;
    [self setInteger:today forMeta:@"maintenance"];
    NSTimeInterval age = self.ageLimit;
    int64_t cutoff = age > 0 ? today - (int64_t)ceil(age / VibeCacheSecondsPerDay) : INT64_MIN;
    [self repeatStep:^BOOL {
        return cutoff > INT64_MIN && [self removeOldestUsedBefore:cutoff untilBytes:0];
    } then:^{
        [self repeatStep:^BOOL {
            return [self sweepUnnamedShared];
        } then:^{
            [self afterWrite];
            if (completion) {
                completion();
            }
        }];
    }];
}

// One batch of the shared items no entry names. YES when more may remain.
- (BOOL)sweepUnnamedShared {
    sqlite3_stmt *stmt = [self statement:
        "SELECT DISTINCT name FROM shared WHERE NOT EXISTS "
        "(SELECT 1 FROM entries WHERE entries.shared = shared.name) LIMIT ?1"];
    sqlite3_bind_int64(stmt, 1, VibeCacheBatch);
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        [names addObject:VibeCacheColumnText(stmt, 0)];
    }
    sqlite3_reset(stmt);
    if (names.count == 0 || ![self begin]) {
        return NO;
    }
    for (NSString *name in names) {
        [self sweepSharedName:name];
    }
    return [self commit] && names.count == VibeCacheBatch;
}

@end

// MARK: - Testing

@implementation VibeCacheStore (Testing)

- (void)setDayOffsetForTesting:(NSInteger)days {
#if DEBUG
    atomic_store(&_dayOffset, (int64_t)days);
#endif
}

- (void)setStopsBeforeFileRowForTesting:(BOOL)stops {
#if DEBUG
    [self syncOnQueue:^{
        self->_stopsBeforeFileRow = stops;
    }];
#endif
}

- (void)recordUsesNowForTesting {
#if DEBUG
    [self syncOnQueue:^{
        [self flushTouches];
    }];
#endif
}

- (NSArray<NSString *> *)fileNamesForTesting {
#if DEBUG
    return [[NSFileManager.defaultManager contentsOfDirectoryAtPath:_filesPath error:NULL]
        sortedArrayUsingSelector:@selector(compare:)] ?: @[];
#else
    return @[];
#endif
}

@end
